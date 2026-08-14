package cmd

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	ftpserver "github.com/KirCute/ftpserverlib-pasvportmap"
	"github.com/KirCute/sftpd-alist"
	"github.com/alist-org/alist/v3/cmd/flags"
	"github.com/alist-org/alist/v3/internal/bootstrap"
	"github.com/alist-org/alist/v3/internal/conf"
	"github.com/alist-org/alist/v3/internal/frp"
	"github.com/alist-org/alist/v3/internal/fs"
	"github.com/alist-org/alist/v3/pkg/utils"
	"github.com/alist-org/alist/v3/server"
	mcpserver "github.com/alist-org/alist/v3/server/mcp"
	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

type EmbeddedServerOptions struct {
	DataDir string
	LogStd  bool
}

type embeddedHTTPServer struct {
	server   *http.Server
	listener net.Listener
	certFile string
	keyFile  string
}

type embeddedServerRuntime struct {
	servers []*embeddedHTTPServer

	ftpDriver *server.FtpMainDriver
	ftpServer *ftpserver.FtpServer
	sftpDriver *server.SftpDriver
	sftpServer *sftpd.SftpServer

	waitGroup sync.WaitGroup
}

type embeddedServerManager struct {
	operation sync.Mutex
	mu        sync.Mutex

	initialized bool
	running     bool
	dataDir     string
	runtime     *embeddedServerRuntime
}

var embeddedServers = &embeddedServerManager{}

func StartEmbeddedServer(ctx context.Context, opts EmbeddedServerOptions) error {
	if ctx == nil {
		ctx = context.Background()
	}
	if opts.DataDir == "" {
		return errors.New("embedded server data directory is required")
	}
	dataDir, err := filepath.Abs(opts.DataDir)
	if err != nil {
		return fmt.Errorf("resolve embedded server data directory: %w", err)
	}

	embeddedServers.operation.Lock()
	defer embeddedServers.operation.Unlock()

	embeddedServers.mu.Lock()
	if embeddedServers.running {
		if embeddedServers.dataDir != dataDir {
			embeddedServers.mu.Unlock()
			return fmt.Errorf("embedded server is already running with data directory %q", embeddedServers.dataDir)
		}
		embeddedServers.mu.Unlock()
		return nil
	}
	if embeddedServers.initialized && embeddedServers.dataDir != dataDir {
		embeddedServers.mu.Unlock()
		return fmt.Errorf("embedded server cannot change data directory from %q to %q", embeddedServers.dataDir, dataDir)
	}
	firstStart := !embeddedServers.initialized
	embeddedServers.mu.Unlock()

	if err := ctx.Err(); err != nil {
		return err
	}
	if firstStart {
		flags.DataDir = dataDir
		flags.ForceBinDir = false
		flags.LogStd = opts.LogStd
		Init()
		if conf.Conf.DelayedStart != 0 {
			utils.Log.Infof("delayed start for %d seconds", conf.Conf.DelayedStart)
			timer := time.NewTimer(time.Duration(conf.Conf.DelayedStart) * time.Second)
			select {
			case <-timer.C:
			case <-ctx.Done():
				if !timer.Stop() {
					<-timer.C
				}
				return ctx.Err()
			}
		}
		bootstrap.InitOfflineDownloadTools()
		bootstrap.LoadStorages()
		bootstrap.InitTaskManager()
		embeddedServers.mu.Lock()
		embeddedServers.initialized = true
		embeddedServers.dataDir = dataDir
		embeddedServers.mu.Unlock()
	}
	bootstrap.InitFRP()

	if err := ctx.Err(); err != nil {
		return err
	}

	if !flags.Debug && !flags.Dev {
		gin.SetMode(gin.ReleaseMode)
	}

	r := gin.New()
	r.Use(gin.LoggerWithWriter(log.StandardLogger().Out), gin.RecoveryWithWriter(log.StandardLogger().Out))
	server.Init(r)
	var httpHandler http.Handler = r
	if conf.Conf.Scheme.EnableH2c {
		httpHandler = h2c.NewHandler(r, &http2.Server{})
	}

	runtime := &embeddedServerRuntime{}
	if conf.Conf.Scheme.HttpPort != -1 {
		address := net.JoinHostPort(conf.Conf.Scheme.Address, strconv.Itoa(conf.Conf.Scheme.HttpPort))
		utils.Log.Infof("start HTTP server @ %s", address)
		if err := runtime.listen(address, httpHandler, "", ""); err != nil {
			return err
		}
	}
	if conf.Conf.Scheme.HttpsPort != -1 {
		address := net.JoinHostPort(conf.Conf.Scheme.Address, strconv.Itoa(conf.Conf.Scheme.HttpsPort))
		utils.Log.Infof("start HTTPS server @ %s", address)
		if err := runtime.listen(address, r, conf.Conf.Scheme.CertFile, conf.Conf.Scheme.KeyFile); err != nil {
			runtime.shutdown(context.Background())
			return err
		}
	}
	if conf.Conf.Scheme.UnixFile != "" {
		if err := runtime.listenUnix(httpHandler); err != nil {
			runtime.shutdown(context.Background())
			return err
		}
	}
	if conf.Conf.S3.Port != -1 && conf.Conf.S3.Enable {
		s3r := gin.New()
		s3r.Use(gin.LoggerWithWriter(log.StandardLogger().Out), gin.RecoveryWithWriter(log.StandardLogger().Out))
		server.InitS3(s3r)
		address := net.JoinHostPort(conf.Conf.Scheme.Address, strconv.Itoa(conf.Conf.S3.Port))
		utils.Log.Infof("start S3 server @ %s", address)
		var handler http.Handler = s3r
		if conf.Conf.S3.SSL {
			if err := runtime.listen(address, handler, conf.Conf.Scheme.CertFile, conf.Conf.Scheme.KeyFile); err != nil {
				runtime.shutdown(context.Background())
				return err
			}
		} else if err := runtime.listen(address, handler, "", ""); err != nil {
			runtime.shutdown(context.Background())
			return err
		}
	}
	if conf.Conf.FTP.Listen != "" && conf.Conf.FTP.Enable {
		driver, err := server.NewMainDriver()
		if err != nil {
			runtime.shutdown(context.Background())
			return fmt.Errorf("failed to start ftp driver: %w", err)
		}
		runtime.ftpDriver = driver
		runtime.ftpServer = ftpserver.NewFtpServer(driver)
		utils.Log.Infof("start ftp server on %s", conf.Conf.FTP.Listen)
		runtime.waitGroup.Add(1)
		go func() {
			defer runtime.waitGroup.Done()
			if err := runtime.ftpServer.ListenAndServe(); err != nil {
				utils.Log.Errorf("problem ftp server listening: %s", err.Error())
			}
		}()
	}
	if conf.Conf.SFTP.Listen != "" && conf.Conf.SFTP.Enable {
		driver, err := server.NewSftpDriver()
		if err != nil {
			runtime.shutdown(context.Background())
			return fmt.Errorf("failed to start sftp driver: %w", err)
		}
		runtime.sftpDriver = driver
		runtime.sftpServer = sftpd.NewSftpServer(driver)
		utils.Log.Infof("start sftp server on %s", conf.Conf.SFTP.Listen)
		runtime.waitGroup.Add(1)
		go func() {
			defer runtime.waitGroup.Done()
			if err := runtime.sftpServer.RunServer(); err != nil {
				utils.Log.Errorf("problem sftp server listening: %s", err.Error())
			}
		}()
	}
	if conf.Conf.MCP.Port != -1 && conf.Conf.MCP.Enable {
		mcpHandler := mcpserver.NewHTTPHandler()
		address := net.JoinHostPort(conf.Conf.Scheme.Address, strconv.Itoa(conf.Conf.MCP.Port))
		utils.Log.Infof("start MCP server @ %s", address)
		if err := runtime.listen(address, mcpHandler, "", ""); err != nil {
			runtime.shutdown(context.Background())
			return err
		}
	}

	embeddedServers.mu.Lock()
	embeddedServers.runtime = runtime
	embeddedServers.running = true
	embeddedServers.mu.Unlock()
	return nil
}

func StopEmbeddedServer(ctx context.Context) error {
	if ctx == nil {
		ctx = context.Background()
	}
	embeddedServers.operation.Lock()
	defer embeddedServers.operation.Unlock()

	embeddedServers.mu.Lock()
	if !embeddedServers.running || embeddedServers.runtime == nil {
		embeddedServers.mu.Unlock()
		return nil
	}
	runtime := embeddedServers.runtime
	embeddedServers.running = false
	embeddedServers.runtime = nil
	embeddedServers.mu.Unlock()

	if fs.ArchiveContentUploadTaskManager.Manager != nil {
		fs.ArchiveContentUploadTaskManager.RemoveAll()
	}
	if frp.Instance != nil {
		frp.Instance.Stop()
	}
	if err := runtime.shutdown(ctx); err != nil {
		return err
	}
	return nil
}

func EmbeddedServerRunning() bool {
	embeddedServers.mu.Lock()
	defer embeddedServers.mu.Unlock()
	return embeddedServers.running
}

func (runtime *embeddedServerRuntime) listen(address string, handler http.Handler, certFile, keyFile string) error {
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return fmt.Errorf("listen %s: %w", address, err)
	}
	entry := &embeddedHTTPServer{
		server:   &http.Server{Addr: address, Handler: handler},
		listener: listener,
		certFile: certFile,
		keyFile:  keyFile,
	}
	runtime.servers = append(runtime.servers, entry)
	runtime.waitGroup.Add(1)
	go func() {
		defer runtime.waitGroup.Done()
		var serveErr error
		if certFile != "" || keyFile != "" {
			serveErr = entry.server.ServeTLS(listener, certFile, keyFile)
		} else {
			serveErr = entry.server.Serve(listener)
		}
		if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			utils.Log.Errorf("server %s stopped: %s", address, serveErr.Error())
		}
	}()
	return nil
}

func (runtime *embeddedServerRuntime) listenUnix(handler http.Handler) error {
	address := conf.Conf.Scheme.UnixFile
	listener, err := net.Listen("unix", address)
	if err != nil {
		return fmt.Errorf("listen unix %s: %w", address, err)
	}
	mode, err := strconv.ParseUint(conf.Conf.Scheme.UnixFilePerm, 8, 32)
	if err != nil {
		_ = listener.Close()
		return fmt.Errorf("parse unix socket permission: %w", err)
	}
	if err := os.Chmod(address, os.FileMode(mode)); err != nil {
		_ = listener.Close()
		return fmt.Errorf("chmod unix socket: %w", err)
	}
	entry := &embeddedHTTPServer{server: &http.Server{Handler: handler}, listener: listener}
	runtime.servers = append(runtime.servers, entry)
	runtime.waitGroup.Add(1)
	go func() {
		defer runtime.waitGroup.Done()
		if err := entry.server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			utils.Log.Errorf("unix server stopped: %s", err.Error())
		}
	}()
	return nil
}

func (runtime *embeddedServerRuntime) shutdown(parent context.Context) error {
	ctx, cancel := context.WithTimeout(parent, time.Second)
	defer cancel()
	var firstErr error
	for _, entry := range runtime.servers {
		if err := entry.server.Shutdown(ctx); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if runtime.ftpServer != nil && runtime.ftpDriver != nil {
		runtime.ftpDriver.Stop()
		if err := runtime.ftpServer.Stop(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if runtime.sftpServer != nil && runtime.sftpDriver != nil {
		if err := runtime.sftpServer.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	runtime.waitGroup.Wait()
	return firstErr
}
