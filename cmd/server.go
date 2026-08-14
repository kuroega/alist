package cmd

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/alist-org/alist/v3/cmd/flags"
	"github.com/alist-org/alist/v3/pkg/utils"
	"github.com/spf13/cobra"
)

// ServerCmd represents the server command
var ServerCmd = &cobra.Command{
	Use:   "server",
	Short: "Start the server at the specified address",
	Long: `Start the server at the specified address
the address is defined in config file`,
	Run: func(cmd *cobra.Command, args []string) {
		if err := StartEmbeddedServer(context.Background(), EmbeddedServerOptions{
			DataDir: flags.DataDir,
			LogStd:  flags.LogStd,
		}); err != nil {
			utils.Log.Fatal("failed to start server: ", err)
		}

		quit := make(chan os.Signal, 1)
		signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
		<-quit
		signal.Stop(quit)
		utils.Log.Println("Shutdown server...")
		if err := StopEmbeddedServer(context.Background()); err != nil {
			utils.Log.Error("server shutdown err: ", err)
		}
		Release()
		utils.Log.Println("Server exit")
	},
}

func init() {
	RootCmd.AddCommand(ServerCmd)
}
