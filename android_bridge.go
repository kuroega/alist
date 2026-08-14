//go:build android && cgo

package main

/*
#include <jni.h>
#include <stdlib.h>

static const char *alist_get_string_utf(JNIEnv *env, jstring value) {
	if (env == NULL || value == NULL) {
		return NULL;
	}
	return (*env)->GetStringUTFChars(env, value, NULL);
}

static void alist_release_string_utf(JNIEnv *env, jstring value, const char *chars) {
	if (env != NULL && value != NULL && chars != NULL) {
		(*env)->ReleaseStringUTFChars(env, value, chars);
	}
}

static jstring alist_new_string_utf(JNIEnv *env, const char *value) {
	if (env == NULL || value == NULL) {
		return NULL;
	}
	return (*env)->NewStringUTF(env, value);
}
*/
import "C"

import (
	"context"
	"errors"
	"sync"
	"unsafe"

	"github.com/alist-org/alist/v3/cmd"
)

const (
	bridgeOK             = 0
	bridgeIdempotent     = 1
	bridgeInvalidRequest = 2
	bridgeFailure        = 3
)

var bridgeState struct {
	sync.Mutex
	lastError string
}

func setBridgeError(err error) {
	bridgeState.Lock()
	defer bridgeState.Unlock()
	if err == nil {
		bridgeState.lastError = ""
		return
	}
	bridgeState.lastError = err.Error()
}

func bridgeLastError() string {
	bridgeState.Lock()
	defer bridgeState.Unlock()
	return bridgeState.lastError
}

func readJNIString(env *C.JNIEnv, value C.jstring) (string, error) {
	if env == nil {
		return "", errors.New("JNI environment is null")
	}
	chars := C.alist_get_string_utf(env, value)
	if chars == nil {
		return "", errors.New("JNI string is null or unreadable")
	}
	defer C.alist_release_string_utf(env, value, chars)
	return C.GoString(chars), nil
}

func newJNIString(env *C.JNIEnv, value string) C.jstring {
	chars := C.CString(value)
	defer C.free(unsafe.Pointer(chars))
	return C.alist_new_string_utf(env, chars)
}

//export Java_com_alist_android_NativeBridge_start
func Java_com_alist_android_NativeBridge_start(env *C.JNIEnv, obj C.jobject, dataDir C.jstring, port C.jint) C.jint {
	_ = obj
	if port < 1 || port > 65535 {
		err := errors.New("invalid backend HTTP port")
		setBridgeError(err)
		return bridgeInvalidRequest
	}
	path, err := readJNIString(env, dataDir)
	if err != nil || path == "" {
		if err == nil {
			err = errors.New("backend data directory is empty")
		}
		setBridgeError(err)
		return bridgeInvalidRequest
	}
	wasRunning := cmd.EmbeddedServerRunning()
	if err := cmd.StartEmbeddedServer(context.Background(), cmd.EmbeddedServerOptions{
		DataDir: path,
		LogStd:  true,
	}); err != nil {
		setBridgeError(err)
		return bridgeFailure
	}
	if wasRunning {
		setBridgeError(nil)
		return bridgeIdempotent
	}
	setBridgeError(nil)
	return bridgeOK
}

//export Java_com_alist_android_NativeBridge_stop
func Java_com_alist_android_NativeBridge_stop(env *C.JNIEnv, obj C.jobject) C.jint {
	_ = env
	_ = obj
	if !cmd.EmbeddedServerRunning() {
		setBridgeError(nil)
		return bridgeIdempotent
	}
	if err := cmd.StopEmbeddedServer(context.Background()); err != nil {
		setBridgeError(err)
		return bridgeFailure
	}
	setBridgeError(nil)
	return bridgeOK
}

//export Java_com_alist_android_NativeBridge_lastError
func Java_com_alist_android_NativeBridge_lastError(env *C.JNIEnv, obj C.jobject) C.jstring {
	_ = obj
	return newJNIString(env, bridgeLastError())
}
