package com.alist.android

class NativeBridge {
    companion object {
        init {
            System.loadLibrary("alist")
        }
    }

    external fun start(dataDir: String, port: Int): Int

    external fun stop(): Int

    external fun lastError(): String
}
