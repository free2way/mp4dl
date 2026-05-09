package com.pqw.xvideo

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.util.Locale
import java.util.UUID
import kotlin.concurrent.thread

class MainActivity : Activity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val supportedHosts = setOf("x.com", "twitter.com", "youtube.com", "youtu.be", "bilibili.com", "b23.tv")

    private lateinit var urlInput: EditText
    private lateinit var qualitySpinner: Spinner
    private lateinit var statusText: TextView
    private lateinit var detailText: TextView
    private lateinit var pathText: TextView
    private lateinit var parseButton: Button
    private lateinit var downloadButton: Button
    private lateinit var updateButton: Button
    private lateinit var progressBar: ProgressBar

    @Volatile
    private var engineReady = false

    @Volatile
    private var currentProcessId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = SURFACE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        }

        buildUi()
        requestStoragePermissionIfNeeded()
        loadIncomingUrl(intent)
        initializeEngine()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        loadIncomingUrl(intent)
    }

    private fun buildUi() {
        val scroll = ScrollView(this)
        scroll.setBackgroundColor(SURFACE)

        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(dp(22), dp(28), dp(22), dp(28))
        scroll.addView(root, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)

        val eyebrow = label("PHONE DOWNLOADER", 12, MUTED)
        root.addView(eyebrow)

        val title = label("X Video", 34, INK)
        title.typeface = android.graphics.Typeface.DEFAULT_BOLD
        title.setPadding(0, dp(4), 0, dp(2))
        root.addView(title)

        val subtitle = label("Paste a public video link and save it on this phone.", 15, MUTED)
        subtitle.setPadding(0, 0, 0, dp(22))
        root.addView(subtitle)

        urlInput = EditText(this)
        urlInput.hint = "X / YouTube / Bilibili link"
        urlInput.inputType = InputType.TYPE_TEXT_VARIATION_URI
        urlInput.setSingleLine(false)
        urlInput.minLines = 3
        urlInput.gravity = Gravity.TOP
        urlInput.setTextColor(INK)
        urlInput.setHintTextColor(MUTED)
        urlInput.setBackgroundColor(Color.WHITE)
        urlInput.setPadding(dp(14), dp(12), dp(14), dp(12))
        root.addView(urlInput, matchWrap())

        val pasteButton = actionButton("Paste link", false)
        pasteButton.setOnClickListener { pasteFromClipboard() }
        root.addView(pasteButton, matchWrap(top = 10))

        qualitySpinner = Spinner(this)
        val choices = DownloadChoice.entries.map { it.label }
        qualitySpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, choices)
        detailText = label(DownloadChoice.BEST_MP4.description, 14, MUTED)
        qualitySpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                detailText.text = DownloadChoice.entries[position].description
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
        root.addView(sectionLabel("Quality"))
        root.addView(qualitySpinner, matchWrap(top = 8))

        detailText.setPadding(0, dp(8), 0, dp(12))
        root.addView(detailText)

        pathText = label("Save path: ${downloadDirectory().absolutePath}", 13, MUTED)
        pathText.setPadding(0, 0, 0, dp(18))
        root.addView(pathText)

        parseButton = actionButton("Check video", false)
        parseButton.setOnClickListener { checkVideo() }
        root.addView(parseButton, matchWrap())

        downloadButton = actionButton("Download", true)
        downloadButton.isEnabled = false
        downloadButton.setOnClickListener { toggleDownload() }
        root.addView(downloadButton, matchWrap(top = 10))

        updateButton = actionButton("Update engine", false)
        updateButton.isEnabled = false
        updateButton.setOnClickListener { updateEngine() }
        root.addView(updateButton, matchWrap(top = 10))

        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal)
        progressBar.max = 100
        progressBar.progress = 0
        root.addView(progressBar, matchWrap(top = 22))

        statusText = label("Initializing downloader...", 15, INK)
        statusText.setPadding(0, dp(12), 0, 0)
        root.addView(statusText)

        setContentView(scroll)
    }

    private fun initializeEngine() {
        setWorking(true, "Initializing downloader...")
        thread(name = "ytdlp-init") {
            try {
                YoutubeDL.getInstance().init(applicationContext)
                FFmpeg.getInstance().init(applicationContext)
                ensureDownloadDirectory()
                engineReady = true
                runOnUi {
                    setWorking(false, "Ready")
                    downloadButton.isEnabled = true
                    updateButton.isEnabled = true
                }
            } catch (error: Throwable) {
                runOnUi {
                    setWorking(false, "Initialization failed: ${cleanMessage(error)}")
                    updateButton.isEnabled = false
                    downloadButton.isEnabled = false
                }
            }
        }
    }

    private fun checkVideo() {
        val url = normalizedUrl() ?: return
        setWorking(true, "Checking video...")
        thread(name = "ytdlp-check") {
            try {
                val request = YoutubeDLRequest(url)
                request.addOption("--no-playlist")
                request.addOption("--dump-json")
                val response = YoutubeDL.getInstance().execute(request, null, null)
                val info = firstJsonObject(response.out)
                val title = info?.optString("title")?.takeIf { it.isNotBlank() } ?: "Untitled video"
                val extractor = info?.optString("extractor_key")?.takeIf { it.isNotBlank() } ?: "video"
                val duration = info?.optDouble("duration")?.takeIf { it > 0 }?.let { formatDuration(it.toLong()) }
                val summary = listOfNotNull(title, extractor, duration).joinToString("\n")
                runOnUi { setWorking(false, summary) }
            } catch (error: Throwable) {
                runOnUi { setWorking(false, "Check failed: ${cleanMessage(error)}") }
            }
        }
    }

    private fun toggleDownload() {
        val runningId = currentProcessId
        if (runningId != null) {
            YoutubeDL.getInstance().destroyProcessById(runningId)
            setWorking(true, "Canceling download...")
            return
        }
        startDownload()
    }

    private fun startDownload() {
        val url = normalizedUrl() ?: return
        val choice = DownloadChoice.entries[qualitySpinner.selectedItemPosition]
        val targetDir = ensureDownloadDirectory()
        val processId = UUID.randomUUID().toString()
        currentProcessId = processId
        progressBar.progress = 0
        setDownloadUi(running = true)
        setWorking(true, "Starting download...")

        thread(name = "ytdlp-download") {
            try {
                val request = YoutubeDLRequest(url)
                request.addOption("--no-playlist")
                request.addOption("--newline")
                request.addOption("--no-mtime")
                request.addOption("-P", targetDir.absolutePath)
                request.addOption("-o", "%(title).180s [%(id)s].%(ext)s")
                choice.applyTo(request)

                YoutubeDL.getInstance().execute(request, processId, true) { progress, etaInSeconds, line ->
                    runOnUi {
                        if (progress in 0f..100f) {
                            progressBar.progress = progress.toInt()
                        }
                        val eta = if (etaInSeconds > 0) " ETA ${formatDuration(etaInSeconds)}" else ""
                        val message = line.takeIf { it.isNotBlank() } ?: "Downloading..."
                        statusText.text = "$message$eta"
                    }
                }

                runOnUi {
                    progressBar.progress = 100
                    setWorking(false, "Saved to ${targetDir.absolutePath}")
                    setDownloadUi(running = false)
                    currentProcessId = null
                }
            } catch (canceled: YoutubeDL.CanceledException) {
                runOnUi {
                    setWorking(false, "Download canceled")
                    setDownloadUi(running = false)
                    currentProcessId = null
                }
            } catch (error: Throwable) {
                runOnUi {
                    setWorking(false, "Download failed: ${cleanMessage(error)}")
                    setDownloadUi(running = false)
                    currentProcessId = null
                }
            }
        }
    }

    private fun updateEngine() {
        if (!engineReady) return
        setWorking(true, "Updating yt-dlp...")
        thread(name = "ytdlp-update") {
            try {
                val status = YoutubeDL.getInstance().updateYoutubeDL(applicationContext)
                runOnUi { setWorking(false, "Engine update: ${status?.name ?: "done"}") }
            } catch (error: Throwable) {
                runOnUi { setWorking(false, "Update failed: ${cleanMessage(error)}") }
            }
        }
    }

    private fun normalizedUrl(): String? {
        val url = urlInput.text.toString().trim()
        if (url.isBlank()) {
            toast("Paste a video link first")
            return null
        }
        val host = try {
            URI(url).host?.lowercase(Locale.US)?.removePrefix("www.")
        } catch (_: Exception) {
            null
        }
        if (host == null || supportedHosts.none { host == it || host.endsWith(".$it") }) {
            toast("Use an X, YouTube, or Bilibili link")
            return null
        }
        hideKeyboard()
        return url
    }

    private fun loadIncomingUrl(intent: Intent?) {
        val incoming = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.dataString
            Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        }
        if (!incoming.isNullOrBlank()) {
            urlInput.setText(incoming.trim())
        }
    }

    private fun pasteFromClipboard() {
        val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val item: ClipData.Item? = manager.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        val text = item?.coerceToText(this)?.toString()?.trim()
        if (text.isNullOrBlank()) {
            toast("Clipboard is empty")
        } else {
            urlInput.setText(text)
            urlInput.setSelection(urlInput.text.length)
        }
    }

    private fun requestStoragePermissionIfNeeded() {
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), STORAGE_PERMISSION_REQUEST)
        }
    }

    private fun ensureDownloadDirectory(): File {
        val dir = downloadDirectory()
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    @Suppress("DEPRECATION")
    private fun downloadDirectory(): File {
        return File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "X Video")
    }

    private fun firstJsonObject(raw: String): JSONObject? {
        return raw.lineSequence()
            .map { it.trim() }
            .firstOrNull { it.startsWith("{") && it.endsWith("}") }
            ?.let { JSONObject(it) }
    }

    private fun setDownloadUi(running: Boolean) {
        downloadButton.text = if (running) "Cancel" else "Download"
        parseButton.isEnabled = !running
        updateButton.isEnabled = !running && engineReady
        qualitySpinner.isEnabled = !running
        urlInput.isEnabled = !running
    }

    private fun setWorking(working: Boolean, message: String) {
        statusText.text = message
        parseButton.isEnabled = engineReady && !working && currentProcessId == null
        downloadButton.isEnabled = engineReady && (!working || currentProcessId != null)
        updateButton.isEnabled = engineReady && !working && currentProcessId == null
    }

    private fun runOnUi(block: () -> Unit) {
        mainHandler.post(block)
    }

    private fun hideKeyboard() {
        val input = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        input.hideSoftInputFromWindow(urlInput.windowToken, 0)
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun cleanMessage(error: Throwable): String {
        val message = error.message ?: error.javaClass.simpleName
        return message.lineSequence().firstOrNull { it.isNotBlank() }?.take(220) ?: "unknown error"
    }

    private fun formatDuration(seconds: Long): String {
        val safeSeconds = seconds.coerceAtLeast(0)
        val hours = safeSeconds / 3600
        val minutes = safeSeconds % 3600 / 60
        val remaining = safeSeconds % 60
        return if (hours > 0) {
            "%d:%02d:%02d".format(hours, minutes, remaining)
        } else {
            "%d:%02d".format(minutes, remaining)
        }
    }

    private fun label(text: String, sp: Int, color: Int): TextView {
        return TextView(this).apply {
            this.text = text
            textSize = sp.toFloat()
            setTextColor(color)
            includeFontPadding = true
        }
    }

    private fun sectionLabel(text: String): TextView {
        return label(text, 13, INK).apply {
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            setPadding(0, dp(20), 0, 0)
        }
    }

    private fun actionButton(text: String, primary: Boolean): Button {
        return Button(this).apply {
            this.text = text
            isAllCaps = false
            minHeight = dp(52)
            textSize = 16f
            setTextColor(if (primary) Color.WHITE else INK)
            setBackgroundColor(if (primary) ACCENT else Color.WHITE)
        }
    }

    private fun matchWrap(top: Int = 0): LinearLayout.LayoutParams {
        return LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply {
            if (top > 0) topMargin = dp(top)
        }
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private enum class DownloadChoice(val label: String, val description: String) {
        BEST_MP4("Best MP4", "Highest quality video with MP4 merge when possible."),
        VIDEO_1080("1080p", "Best MP4 video up to 1080p."),
        VIDEO_720("720p", "Best MP4 video up to 720p."),
        AUDIO_MP3("Audio MP3", "Extract audio and save as MP3.");

        fun applyTo(request: YoutubeDLRequest) {
            when (this) {
                BEST_MP4 -> {
                    request.addOption("-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best")
                    request.addOption("--merge-output-format", "mp4")
                }
                VIDEO_1080 -> {
                    request.addOption("-f", "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080][ext=mp4]/best[height<=1080]")
                    request.addOption("--merge-output-format", "mp4")
                }
                VIDEO_720 -> {
                    request.addOption("-f", "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/best[height<=720][ext=mp4]/best[height<=720]")
                    request.addOption("--merge-output-format", "mp4")
                }
                AUDIO_MP3 -> {
                    request.addOption("-x")
                    request.addOption("--audio-format", "mp3")
                    request.addOption("--audio-quality", "0")
                }
            }
        }
    }

    companion object {
        private const val STORAGE_PERMISSION_REQUEST = 4101
        private val SURFACE = Color.rgb(247, 245, 240)
        private val INK = Color.rgb(23, 23, 23)
        private val MUTED = Color.rgb(103, 99, 91)
        private val ACCENT = Color.rgb(14, 143, 114)
    }
}
