package com.alist.android

import android.net.Uri
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

const val DEFAULT_HTTP_PORT = 5244

class BackendEndpoint(val port: Int, val basePath: String) {
    private val prefix = if (basePath == "/") "" else basePath

    val baseUrl: String
        get() = "http://127.0.0.1:$port$prefix/"

    val pingUrl: String
        get() = endpoint("ping")

    val settingsUrl: String
        get() = endpoint("api/public/settings")

    private fun endpoint(path: String): String = "http://127.0.0.1:$port$prefix/$path"
}

object BackendConfig {
    fun prepare(dataDir: File, port: Int = DEFAULT_HTTP_PORT): BackendEndpoint {
        require(port in 1..65535) { "backend HTTP port must be between 1 and 65535" }
        if (!dataDir.exists() && !dataDir.mkdirs()) {
            throw IllegalStateException("cannot create backend data directory: $dataDir")
        }
        if (!dataDir.isDirectory || !dataDir.canWrite()) {
            throw IllegalStateException("backend data directory is not writable: $dataDir")
        }

        val configFile = File(dataDir, "config.json")
        val config = readConfig(configFile)
        val basePath = parseBasePath(config.optString("site_url", ""))
        applyAndroidDefaults(config, dataDir, port)
        writeConfigAtomically(configFile, config)
        return BackendEndpoint(port, basePath)
    }

    private fun readConfig(configFile: File): JSONObject {
        if (!configFile.exists()) return JSONObject()
        val source = try {
            configFile.readText(Charsets.UTF_8)
        } catch (error: Exception) {
            throw IllegalStateException("cannot read backend config: $configFile", error)
        }
        return try {
            JSONObject(source)
        } catch (error: JSONException) {
            throw IllegalStateException("backend config is invalid JSON: $configFile", error)
        }
    }

    private fun parseBasePath(siteUrl: String): String {
        val value = siteUrl.trim()
        if (value.isEmpty()) return "/"
        val uri = try {
            URI(value)
        } catch (error: Exception) {
            throw IllegalArgumentException("site_url is not a valid URL or path", error)
        }
        val rawPath = if (uri.isAbsolute) {
            uri.rawPath ?: "/"
        } else {
            uri.path ?: value
        }
        var path = Uri.decode(rawPath).trim()
        if (path.isEmpty()) path = "/"
        if (!path.startsWith('/')) path = "/$path"
        path = path.replace(Regex("/{2,}"), "/")
        if (path.length > 1) path = path.trimEnd('/')
        return path.ifEmpty { "/" }
    }

    private fun applyAndroidDefaults(config: JSONObject, dataDir: File, port: Int) {
        config.put("force", true)
        config.put("dist_dir", "")
        config.put("temp_dir", File(dataDir, "temp").absolutePath)
        config.put("bleve_dir", File(dataDir, "bleve").absolutePath)
        config.put("delayed_start", 0)

        val scheme = config.optJSONObject("scheme") ?: JSONObject().also { config.put("scheme", it) }
        scheme.put("address", "127.0.0.1")
        scheme.put("http_port", port)
        scheme.put("https_port", -1)
        scheme.put("force_https", false)
        scheme.put("unix_file", "")

        val database = config.optJSONObject("database") ?: JSONObject().also { config.put("database", it) }
        database.put("db_file", File(dataDir, "data.db").absolutePath)

        val log = config.optJSONObject("log") ?: JSONObject().also { config.put("log", it) }
        log.put("name", File(dataDir, "log/log.log").absolutePath)

        disableOptionalService(config, "s3")
        disableOptionalService(config, "ftp")
        disableOptionalService(config, "sftp")
        disableOptionalService(config, "mcp")
    }

    private fun disableOptionalService(config: JSONObject, key: String) {
        val service = config.optJSONObject(key) ?: JSONObject().also { config.put(key, it) }
        service.put("enable", false)
    }

    private fun writeConfigAtomically(configFile: File, config: JSONObject) {
        val tempFile = File(configFile.parentFile, ".config.json.tmp")
        try {
            FileOutputStream(tempFile).use { output ->
                output.write(config.toString(2).toByteArray(StandardCharsets.UTF_8))
                output.fd.sync()
            }
            try {
                Files.move(
                    tempFile.toPath(),
                    configFile.toPath(),
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(
                    tempFile.toPath(),
                    configFile.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
        } catch (error: Exception) {
            tempFile.delete()
            throw IllegalStateException("cannot write backend config: $configFile", error)
        }
    }
}
