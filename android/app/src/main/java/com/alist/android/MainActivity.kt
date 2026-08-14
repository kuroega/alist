package com.alist.android

import android.Manifest
import android.app.Activity
import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.DownloadListener
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebViewClient
import android.net.http.SslError
import android.widget.Toast
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : Activity() {
    companion object {
        private const val REQUEST_FILE = 1001
        private const val REQUEST_STORAGE = 1002
        private const val PROBE_TIMEOUT_MS = 60_000L
        private const val EXTRA_HTTP_HEADERS = "android.intent.extra.HTTP_HEADERS"
        private const val QUARK_PAN_URL = "https://pan.quark.cn/"
        private const val QUARK_DRIVE_URL = "https://drive.quark.cn/"
        private const val QUARK_MIN_PAGE_ZOOM = 75
        private const val QUARK_MAX_PAGE_ZOOM = 200
        private const val QUARK_DEFAULT_PAGE_ZOOM = 100
        private const val QUARK_PAGE_ZOOM_STEP = 25
    }

    private lateinit var root: FrameLayout
    private lateinit var webView: WebView
    private lateinit var progress: ProgressBar
    private lateinit var status: TextView
    private lateinit var retry: Button
    private val mainHandler = Handler(Looper.getMainLooper())
    private val probeExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "alist-readiness").apply { isDaemon = true }
    }
    private val probing = AtomicBoolean(false)
    private var endpoint: BackendEndpoint? = null
    private var fileChooserCallback: ValueCallback<Array<Uri>>? = null
    private var pendingDownload: DownloadSpec? = null
    private var receiverRegistered = false
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null
    private var isFullscreen = false
    private var contentInsets = SafeInsets()
    private var quarkLoginOverlay: View? = null
    private var quarkLoginWebView: WebView? = null

    private data class ExternalPlaybackSpec(
        val url: String,
        val mimeType: String?,
        val referer: String?,
        val userAgent: String?,
        val cookie: String?,
    )

    private data class DownloadSpec(
        val url: String,
        val userAgent: String?,
        val contentDisposition: String?,
        val mimeType: String?,
    )
    private data class SafeInsets(
        val left: Int = 0,
        val top: Int = 0,
        val right: Int = 0,
        val bottom: Int = 0,
    )

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val error = intent?.getStringExtra(AlistService.EXTRA_ERROR)
            if (!error.isNullOrBlank()) {
                showFailure(error)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        configureWindow()
        buildUi()
        configureWebView()
        registerStatusReceiver()
        requestNotificationPermission()
        startBackend()
    }

    override fun onStart() {
        super.onStart()
        if (!receiverRegistered) registerStatusReceiver()
    }

    override fun onStop() {
        if (receiverRegistered) {
            unregisterReceiver(statusReceiver)
            receiverRegistered = false
        }
        super.onStop()
    }

    override fun onDestroy() {
        probing.set(false)
        probeExecutor.shutdownNow()
        mainHandler.removeCallbacksAndMessages(null)
        if (receiverRegistered) {
            unregisterReceiver(statusReceiver)
            receiverRegistered = false
        }
        closeQuarkCookieLogin()
        if (::webView.isInitialized) {
            webView.stopLoading()
            webView.webChromeClient = null
            webView.destroy()
        }
        super.onDestroy()
    }

    @Deprecated("Use back handling in the WebView while retaining framework compatibility")
    override fun onBackPressed() {
        if (quarkLoginOverlay != null) {
            closeQuarkCookieLogin()
            return
        }
        if (::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
        } else {
            super.onBackPressed()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_FILE) {
            val callback = fileChooserCallback ?: return
            fileChooserCallback = null
            val uris = when {
                resultCode != RESULT_OK -> null
                data?.clipData != null -> Array(data.clipData!!.itemCount) { index ->
                    data.clipData!!.getItemAt(index).uri
                }
                data?.data != null -> arrayOf(data.data!!)
                else -> null
            }
            callback.onReceiveValue(uris)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_STORAGE) {
            val download = pendingDownload ?: return
            pendingDownload = null
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            enqueueDownload(download, usePublicDirectory = granted)
        }
    }

    private fun buildUi() {
        root = FrameLayout(this).apply {
            setBackgroundColor(Color.WHITE)
        }
        webView = WebView(this)
        root.addView(
            webView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        val overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        progress = ProgressBar(this)
        status = TextView(this).apply {
            setTextColor(Color.DKGRAY)
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(0, dp(16), 0, dp(16))
        }
        retry = Button(this).apply {
            text = getString(R.string.backend_retry)
            visibility = View.GONE
            setOnClickListener { restartBackend() }
        }
        overlay.addView(progress)
        overlay.addView(status)
        overlay.addView(retry)
        root.addView(
            overlay,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        setContentView(root)
        root.setOnApplyWindowInsetsListener { _, insets ->
            contentInsets = readSafeInsets(insets)
            if (!isFullscreen) applyContentInsets()
            insets
        }
        root.requestApplyInsets()
        showStarting()
    }
    private fun configureWindow() {
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = baseSystemUiVisibility()
        }
    }

    private fun baseSystemUiVisibility(): Int {
        var flags = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            flags = flags or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        }
        return flags
    }

    private fun readSafeInsets(insets: WindowInsets): SafeInsets {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bars = insets.getInsets(
                WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
            )
            return SafeInsets(bars.left, bars.top, bars.right, bars.bottom)
        }
        @Suppress("DEPRECATION")
        return SafeInsets(
            insets.systemWindowInsetLeft,
            insets.systemWindowInsetTop,
            insets.systemWindowInsetRight,
            insets.systemWindowInsetBottom,
        )
    }

    private fun applyContentInsets() {
        root.setPadding(
            contentInsets.left,
            contentInsets.top,
            contentInsets.right,
            contentInsets.bottom,
        )
    }

    private fun enterFullscreenWindow() {
        isFullscreen = true
        root.setPadding(0, 0, 0, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let { controller ->
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsets.Type.systemBars())
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = baseSystemUiVisibility() or
                View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        }
    }

    private fun exitFullscreenWindow() {
        isFullscreen = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.show(WindowInsets.Type.systemBars())
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = baseSystemUiVisibility()
        }
        applyContentInsets()
        root.requestApplyInsets()
    }

    private fun configureWebView() {
        webView.addJavascriptInterface(AndroidJavascriptBridge(this), "AlistAndroid")
        val settings = webView.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        settings.allowFileAccess = false
        settings.allowContentAccess = true
        settings.cacheMode = WebSettings.LOAD_DEFAULT
        CookieManager.getInstance().setAcceptCookie(true)
        if (BuildConfig.DEBUG) WebView.setWebContentsDebuggingEnabled(true)

        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                super.onPageFinished(view, url)
                if (isLocalUrl(Uri.parse(url))) {
                    installExternalPlaybackControls()
                    webView.evaluateJavascript(QUARK_COOKIE_SCRIPT, null)
                }
            }

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                return handleNavigation(request.url)
            }

            @Suppress("DEPRECATION")
            override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean {
                return handleNavigation(Uri.parse(url))
            }

            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                handler.cancel()
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) {
                    showFailure(error.description?.toString() ?: getString(R.string.backend_failed))
                }
            }
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onShowFileChooser(
                view: WebView,
                callback: ValueCallback<Array<Uri>>,
                params: FileChooserParams,
            ): Boolean {
                fileChooserCallback?.onReceiveValue(null)
                fileChooserCallback = callback
                val intent = try {
                    params.createIntent().apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                } catch (_: Exception) {
                    Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        type = "*/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        addCategory(Intent.CATEGORY_OPENABLE)
                    }
                }
                return try {
                    startActivityForResult(intent, REQUEST_FILE)
                    true
                } catch (_: Exception) {
                    fileChooserCallback = null
                    false
                }
            }

            override fun onCreateWindow(
                view: WebView,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: android.os.Message,
            ): Boolean {
                val popup = WebView(this@MainActivity)
                popup.settings.javaScriptEnabled = true
                popup.settings.domStorageEnabled = true
                popup.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(popupView: WebView, request: WebResourceRequest): Boolean {
                        openExternal(request.url)
                        popupView.destroy()
                        return true
                    }
                }
                val transport = resultMsg.obj as? WebView.WebViewTransport ?: return false
                transport.webView = popup
                resultMsg.sendToTarget()
                return true
            }

            override fun onShowCustomView(view: View, callback: CustomViewCallback) {
                if (customView != null) {
                    callback.onCustomViewHidden()
                    return
                }
                customView = view
                customViewCallback = callback
                root.addView(
                    view,
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    ),
                )
                webView.visibility = View.GONE
                enterFullscreenWindow()
            }

            override fun onHideCustomView() {
                exitFullscreen()
            }
        }
        webView.setDownloadListener(DownloadListener { url, userAgent, contentDisposition, mimeType, _ ->
            handleDownload(DownloadSpec(url, userAgent, contentDisposition, mimeType))
        })
    }

    private fun openQuarkCookieLogin() {
        if (quarkLoginOverlay != null) return

        val overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
            elevation = dp(4).toFloat()
        }
        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(4), dp(8), dp(4))
        }
        val title = TextView(this).apply {
            text = getString(R.string.quark_login_title)
            textSize = 18f
            setTextColor(Color.BLACK)
        }
        val useCookie = Button(this).apply {
            text = getString(R.string.quark_use_current_cookie)
            isAllCaps = false
        }
        val close = Button(this).apply {
            text = getString(R.string.quark_close)
            isAllCaps = false
        }

        val loginWebView = WebView(this)
        var pageZoom = QUARK_DEFAULT_PAGE_ZOOM
        val zoomToolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(8), 0, dp(8), dp(4))
        }
        val zoomOut = Button(this).apply {
            text = getString(R.string.quark_zoom_out_button)
            contentDescription = getString(R.string.quark_zoom_out_content_description)
            isAllCaps = false
        }
        val zoomLabel = TextView(this).apply {
            setTextColor(Color.DKGRAY)
            gravity = Gravity.CENTER
        }
        val zoomIn = Button(this).apply {
            text = getString(R.string.quark_zoom_in_button)
            contentDescription = getString(R.string.quark_zoom_in_content_description)
            isAllCaps = false
        }
        val zoomReset = Button(this).apply {
            text = getString(R.string.quark_zoom_reset_button)
            contentDescription = getString(R.string.quark_zoom_reset_content_description)
            isAllCaps = false
        }
        zoomToolbar.addView(
            zoomOut,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        zoomToolbar.addView(
            zoomLabel,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        zoomToolbar.addView(
            zoomIn,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        zoomToolbar.addView(
            zoomReset,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        fun updatePageZoom(nextZoom: Int) {
            val adjustedZoom = nextZoom.coerceIn(QUARK_MIN_PAGE_ZOOM, QUARK_MAX_PAGE_ZOOM)
            loginWebView.zoomBy(adjustedZoom.toFloat() / pageZoom)
            loginWebView.post {
                if (adjustedZoom > QUARK_DEFAULT_PAGE_ZOOM) {
                    loginWebView.scrollTo(Int.MAX_VALUE, 0)
                } else {
                    loginWebView.scrollTo(0, 0)
                }
            }
            pageZoom = adjustedZoom
            zoomLabel.text = getString(R.string.quark_zoom_label, pageZoom)
            zoomOut.isEnabled = pageZoom > QUARK_MIN_PAGE_ZOOM
            zoomIn.isEnabled = pageZoom < QUARK_MAX_PAGE_ZOOM
            zoomReset.isEnabled = pageZoom != QUARK_DEFAULT_PAGE_ZOOM
        }
        zoomOut.setOnClickListener { updatePageZoom(pageZoom - QUARK_PAGE_ZOOM_STEP) }
        zoomIn.setOnClickListener { updatePageZoom(pageZoom + QUARK_PAGE_ZOOM_STEP) }
        zoomReset.setOnClickListener { updatePageZoom(QUARK_DEFAULT_PAGE_ZOOM) }
        updatePageZoom(QUARK_DEFAULT_PAGE_ZOOM)
        overlay.addView(
            toolbar,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        overlay.addView(
            zoomToolbar,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        overlay.addView(
            loginWebView,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f,
            ),
        )
        quarkLoginOverlay = overlay
        quarkLoginWebView = loginWebView
        root.addView(
            overlay,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        useCookie.setOnClickListener {
            CookieManager.getInstance().flush()
            val cookie = listOf(
                CookieManager.getInstance().getCookie(QUARK_PAN_URL),
                CookieManager.getInstance().getCookie(QUARK_DRIVE_URL),
            ).mapNotNull { value ->
                value?.takeIf { it.isNotBlank() }
            }.joinToString("; ")
            if (cookie.isBlank()) {
                showTransientMessage(getString(R.string.quark_cookie_empty))
                return@setOnClickListener
            }
            deliverQuarkCookie(cookie)
            closeQuarkCookieLogin()
        }
        close.setOnClickListener { closeQuarkCookieLogin() }

        configureQuarkLoginWebView(loginWebView)
        loginWebView.loadUrl(QUARK_PAN_URL)
    }

    private fun configureQuarkLoginWebView(loginWebView: WebView) {
        val settings = loginWebView.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.userAgentString = desktopUserAgent(settings.userAgentString)
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = true
        settings.setSupportZoom(true)
        settings.builtInZoomControls = false
        settings.displayZoomControls = false
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        settings.safeBrowsingEnabled = true
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(loginWebView, false)
        loginWebView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest,
            ): Boolean {
                if (!request.isForMainFrame) return false
                return handleQuarkLoginNavigation(request.url, request.hasGesture())
            }

            @Suppress("DEPRECATION")
            override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean {
                return handleQuarkLoginNavigation(Uri.parse(url), hasGesture = false)
            }

            override fun onReceivedSslError(
                view: WebView,
                handler: SslErrorHandler,
                error: SslError,
            ) {
                handler.cancel()
            }
        }
        loginWebView.webChromeClient = WebChromeClient()
    }

    private fun handleQuarkLoginNavigation(uri: Uri, hasGesture: Boolean): Boolean {
        if (uri.scheme != "https") return true
        val host = uri.host.orEmpty().lowercase()
        if (host == "quark.cn" || host.endsWith(".quark.cn")) return false
        if (hasGesture) {
            openExternal(uri)
        } else {
            showTransientMessage(getString(R.string.quark_navigation_blocked))
        }
        return true
    }

    private fun desktopUserAgent(defaultUserAgent: String): String {
        val chromeVersion = defaultUserAgent
            .substringAfter("Chrome/", missingDelimiterValue = "")
            .substringBefore(' ')
            .takeIf(String::isNotBlank)
            ?: "133.0.0.0"
        return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$chromeVersion Safari/537.36"
    }

    private fun deliverQuarkCookie(cookie: String) {
        if (!::webView.isInitialized || cookie.isBlank()) return
        val cookieLiteral = JSONObject.quote(cookie)
        val script = """
            (function() {
              var cookie = $cookieLiteral;
              if (typeof window.__alistAndroidQuarkCookieReady === "function") {
                window.__alistAndroidQuarkCookieReady(cookie);
              } else {
                window.__alistAndroidQuarkCookiePending = cookie;
              }
            })();
        """.trimIndent()
        webView.evaluateJavascript(script, null)
    }

    private fun closeQuarkCookieLogin() {
        quarkLoginOverlay?.let { overlay ->
            if (::root.isInitialized) root.removeView(overlay)
        }
        quarkLoginOverlay = null
        quarkLoginWebView?.let { loginWebView ->
            loginWebView.stopLoading()
            loginWebView.webViewClient = WebViewClient()
            loginWebView.webChromeClient = null
            loginWebView.destroy()
        }
        quarkLoginWebView = null
    }

    private fun restartBackend() {
        probing.set(false)
        val stopIntent = Intent(this, AlistService::class.java).setAction(AlistService.ACTION_STOP)
        runCatching { startService(stopIntent) }
        mainHandler.postDelayed({ startBackend() }, 500)
    }
    private fun startBackend() {
        if (!probing.compareAndSet(false, true)) return
        showStarting()
        val dataDir = File(filesDir, "alist")
        val preparedEndpoint = try {
            BackendConfig.prepare(dataDir)
        } catch (error: Throwable) {
            probing.set(false)
            showFailure(error.message ?: error.javaClass.simpleName)
            return
        }
        endpoint = preparedEndpoint
        val intent = Intent(this, AlistService::class.java).setAction(AlistService.ACTION_START)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (error: Throwable) {
            probing.set(false)
            showFailure(error.message ?: error.javaClass.simpleName)
            return
        }

        probeExecutor.execute {
            val deadline = SystemClock.elapsedRealtime() + PROBE_TIMEOUT_MS
            var ready = false
            var lastError = ""
            while (probing.get() && SystemClock.elapsedRealtime() < deadline) {
                try {
                    val ping = request(preparedEndpoint.pingUrl)
                    if (ping.status == HttpURLConnection.HTTP_OK && ping.body.trim() == "pong") {
                        val settings = request(preparedEndpoint.settingsUrl)
                        if (settings.status == HttpURLConnection.HTTP_OK && JSONObject(settings.body).optInt("code", -1) == 200) {
                            ready = true
                            break
                        }
                        lastError = "后端正在加载存储"
                    } else {
                        lastError = "后端尚未就绪"
                    }
                } catch (error: Throwable) {
                    lastError = error.message ?: error.javaClass.simpleName
                }
                try {
                    Thread.sleep(250)
                } catch (_: InterruptedException) {
                    break
                }
            }
            mainHandler.post {
                probing.set(false)
                if (ready) {
                    webView.visibility = View.VISIBLE
                    progress.visibility = View.GONE
                    status.visibility = View.GONE
                    retry.visibility = View.GONE
                    webView.loadUrl(preparedEndpoint.baseUrl)
                } else {
                    val nativeError = runCatching { NativeBridge().lastError() }.getOrNull().orEmpty()
                    showFailure(
                        listOf(lastError, nativeError)
                            .firstOrNull { it.isNotBlank() }
                            ?: "超过 ${PROBE_TIMEOUT_MS / 1000} 秒仍未就绪",
                    )
                }
            }
        }
    }

    private data class ProbeResponse(val status: Int, val body: String)

    private fun request(url: String): ProbeResponse {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.connectTimeout = 2_000
        connection.readTimeout = 2_000
        connection.instanceFollowRedirects = false
        connection.useCaches = false
        return try {
            val status = connection.responseCode
            val stream = if (status in 200..399) connection.inputStream else connection.errorStream
            val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            ProbeResponse(status, body)
        } finally {
            connection.disconnect()
        }
    }

    private fun handleNavigation(uri: Uri): Boolean {
        return if (isLocalUrl(uri)) {
            false
        } else {
            openExternal(uri)
            true
        }
    }

    private fun isLocalUrl(uri: Uri): Boolean {
        val currentEndpoint = endpoint ?: return false
        val path = uri.path ?: "/"
        val basePath = currentEndpoint.basePath
        val pathMatches = basePath == "/" || path == basePath || path.startsWith("$basePath/")
        return uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port == currentEndpoint.port && pathMatches
    }

    private fun openExternal(uri: Uri) {
        if (uri.scheme != "http" && uri.scheme != "https") return
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
        } catch (_: Exception) {
            showFailure("无法打开外部链接: $uri")
        }
    }

    private fun installExternalPlaybackControls() {
        webView.evaluateJavascript(EXTERNAL_PLAYBACK_SCRIPT, null)
    }

    private fun openExternalPlayer(spec: ExternalPlaybackSpec) {
        val uri = runCatching { Uri.parse(spec.url) }.getOrNull()
        if (uri == null || (uri.scheme != "http" && uri.scheme != "https")) {
            showTransientMessage("外部播放地址无效")
            return
        }
        if (!spec.referer.isNullOrBlank()) {
            showTransientMessage("暂不支持该规则")
            return
        }
        val mimeType = resolveMediaMimeType(uri, spec.mimeType)
        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mimeType)
        val headers = arrayListOf<String>()
        val cookie = CookieManager.getInstance().getCookie(spec.url)
            .orEmpty()
            .ifBlank { spec.cookie.orEmpty() }
        spec.userAgent?.trim()?.takeIf { it.isNotEmpty() }?.let {
            headers += "User-Agent: $it"
        }
        cookie.trim().takeIf { it.isNotEmpty() }?.let {
            headers += "Cookie: $it"
        }
        if (headers.isNotEmpty()) {
            intent.putExtra(EXTRA_HTTP_HEADERS, headers)
        }
        try {
            startActivity(intent)
            showTransientMessage("尝试唤起外部播放器")
        } catch (_: Exception) {
            showTransientMessage("唤起外部播放器失败")
        }
    }

    private fun resolveMediaMimeType(uri: Uri, suppliedMimeType: String?): String {
        val supplied = suppliedMimeType?.trim()?.lowercase().orEmpty()
        if (supplied.startsWith("video/") || supplied == "application/vnd.apple.mpegurl" ||
            supplied == "application/x-mpegurl"
        ) {
            return supplied
        }
        return when (uri.path?.substringAfterLast('.', "")?.lowercase()) {
            "m3u8" -> "application/vnd.apple.mpegurl"
            "mp4", "m4v" -> "video/mp4"
            "webm" -> "video/webm"
            "mkv" -> "video/x-matroska"
            "mov" -> "video/quicktime"
            else -> "video/*"
        }
    }

    private fun showTransientMessage(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun handleDownload(download: DownloadSpec) {
        if (!download.url.startsWith("http://") && !download.url.startsWith("https://")) return
        if (
            Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        ) {
            pendingDownload = download
            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), REQUEST_STORAGE)
            return
        }
        enqueueDownload(download, usePublicDirectory = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q || checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED)
    }

    @Suppress("DEPRECATION")
    private fun enqueueDownload(download: DownloadSpec, usePublicDirectory: Boolean) {
        val request = DownloadManager.Request(Uri.parse(download.url))
        request.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
        request.setMimeType(download.mimeType ?: "application/octet-stream")
        download.userAgent?.let {
            request.addRequestHeader("User-Agent", it)
        }
        CookieManager.getInstance().getCookie(download.url)?.let {
            request.addRequestHeader("Cookie", it)
        }
        webView.url?.takeIf { it.startsWith("http://") || it.startsWith("https://") }?.let {
            request.addRequestHeader("Referer", it)
        }
        val filename = safeFilename(download.contentDisposition, download.url)
        if (usePublicDirectory) {
            request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, filename)
        } else {
            request.setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, filename)
        }
        try {
            getSystemService(DownloadManager::class.java).enqueue(request)
        } catch (error: Exception) {
            showFailure(error.message ?: "无法创建下载任务")
        }
    }

    private fun safeFilename(contentDisposition: String?, url: String): String {
        val fromHeader = contentDisposition
            ?.let { Regex("filename\\*?=(?:UTF-8''|\\\"?)([^\\\";]+)", RegexOption.IGNORE_CASE).find(it)?.groupValues?.getOrNull(1) }
            ?.let { runCatching { URLDecoder.decode(it, "UTF-8") }.getOrNull() }
        val fromUrl = Uri.parse(url).lastPathSegment
        val candidate = (fromHeader ?: fromUrl ?: "download").trim().ifBlank { "download" }
        return candidate.replace(Regex("[\\\\/:*?\"<>|]"), "_").take(180)
    }

    private fun exitFullscreen() {
        customView?.let { root.removeView(it) }
        customView = null
        customViewCallback?.onCustomViewHidden()
        customViewCallback = null
        webView.visibility = View.VISIBLE
        exitFullscreenWindow()
    }

    private fun registerStatusReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter(AlistService.ACTION_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(statusReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(statusReceiver, filter)
        }
        receiverRegistered = true
    }

    private fun requestNotificationPermission() {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1003)
        }
    }

    private class AndroidJavascriptBridge(private val activity: MainActivity) {
        @JavascriptInterface
        fun openExternalPlayer(
            url: String?,
            mimeType: String?,
            referer: String?,
            userAgent: String?,
            cookie: String?,
        ) {
            val normalizedUrl = url?.trim().orEmpty()
            if (normalizedUrl.isEmpty()) {
                activity.runOnUiThread { activity.showTransientMessage("没有可播放的视频地址") }
                return
            }
            activity.runOnUiThread {
                activity.openExternalPlayer(
                    ExternalPlaybackSpec(
                        url = normalizedUrl,
                        mimeType = mimeType,
                        referer = referer,
                        userAgent = userAgent,
                        cookie = cookie,
                    ),
                )
            }
        }

        @JavascriptInterface
        fun openQuarkCookieLogin() {
            activity.runOnUiThread { activity.openQuarkCookieLogin() }
        }
    }

    private fun showStarting() {
        progress.visibility = View.VISIBLE
        status.visibility = View.VISIBLE
        retry.visibility = View.GONE
        status.text = getString(R.string.backend_starting)
    }

    private fun showFailure(message: String) {
        if (!::status.isInitialized) return
        progress.visibility = View.GONE
        webView.visibility = View.GONE
        status.visibility = View.VISIBLE
        retry.visibility = View.VISIBLE
        val logPath = File(filesDir, "alist/log/log.log").absolutePath
        status.text = "${getString(R.string.backend_failed)}\n$message\n日志：$logPath"
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
