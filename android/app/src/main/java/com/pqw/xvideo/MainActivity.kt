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
import java.io.File
import java.net.URI
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class MainActivity : Activity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val supportedHosts = setOf("x.com", "twitter.com", "youtube.com", "youtu.be", "bilibili.com", "b23.tv")

    private lateinit var urlInput: EditText
    private lateinit var qualitySpinner: Spinner
    private lateinit var concurrencySpinner: Spinner
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
    private var isDownloading = false

    @Volatile
    private var totalJobs = 0

    private var downloadExecutor: ExecutorService? = null
    private val currentProcessIds = ConcurrentHashMap.newKeySet<String>()
    private val finishedJobs = AtomicInteger(0)
    private val failedJobs = AtomicInteger(0)
    private val canceledJobs = AtomicInteger(0)
    private val lastError = AtomicReference<String?>(null)

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

        val subtitle = label("Paste public video links and save them on this phone.", 15, MUTED)
        subtitle.setPadding(0, 0, 0, dp(22))
        root.addView(subtitle)

        urlInput = EditText(this)
        urlInput.hint = "Paste one or more X / YouTube / Bilibili links"
        urlInput.inputType = InputType.TYPE_TEXT_VARIATION_URI
        urlInput.setSingleLine(false)
        urlInput.minLines = 3
        urlInput.gravity = Gravity.TOP
        urlInput.setTextColor(INK)
        urlInput.setHintTextColor(MUTED)
        urlInput.setBackgroundColor(Color.WHITE)
        urlInput.setPadding(dp(14), dp(12), dp(14), dp(12))
        root.addView(urlInput, matchWrap())

        val pasteButton = actionButton("Paste links", false)
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

        concurrencySpinner = Spinner(this)
        concurrencySpinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, (1..MAX_CONCURRENCY).map { "$it downloads" })
        concurrencySpinner.setSelection(2)
        root.addView(sectionLabel("Concurrent downloads"))
        root.addView(concurrencySpinner, matchWrap(top = 8))

        pathText = label("Save path: ${downloadDirectory().absolutePath}", 13, MUTED)
        pathText.setPadding(0, dp(12), 0, dp(18))
        root.addView(pathText)

        parseButton = actionButton("Check links", false)
        parseButton.setOnClickListener { checkVideo() }
        root.addView(parseButton, matchWrap())

        downloadButton = actionButton("Download queue", true)
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
        val urls = normalizedUrls() ?: return
        setWorking(false, "${urls.size} link${if (urls.size == 1) "" else "s"} ready")
    }

    private fun toggleDownload() {
        if (isDownloading) {
            cancelDownloads()
            return
        }
        startDownloads()
    }

    private fun startDownloads() {
        val urls = normalizedUrls() ?: return
        val choice = DownloadChoice.entries[qualitySpinner.selectedItemPosition]
        val targetDir = ensureDownloadDirectory()
        val concurrency = (concurrencySpinner.selectedItemPosition + 1).coerceIn(1, MAX_CONCURRENCY)

        totalJobs = urls.size
        finishedJobs.set(0)
        failedJobs.set(0)
        canceledJobs.set(0)
        lastError.set(null)
        currentProcessIds.clear()
        isDownloading = true
        progressBar.progress = 0
        setDownloadUi(running = true)
        setWorking(true, "Starting ${urls.size} download${if (urls.size == 1) "" else "s"}...")

        val executor = Executors.newFixedThreadPool(concurrency)
        downloadExecutor = executor
        urls.forEachIndexed { index, url ->
            executor.execute {
                runDownloadJob(index + 1, url, choice, targetDir)
            }
        }
        executor.shutdown()
    }

    private fun runDownloadJob(jobNumber: Int, url: String, choice: DownloadChoice, targetDir: File) {
        if (!isDownloading) {
            markJobFinished(canceled = true)
            return
        }

        val processId = UUID.randomUUID().toString()
        currentProcessIds.add(processId)
        try {
            val request = YoutubeDLRequest(url)
            request.addOption("--no-playlist")
            request.addOption("--newline")
            request.addOption("--no-mtime")
            request.addOption("-P", targetDir.absolutePath)
            request.addOption("-o", "%(title).180s [%(id)s].%(ext)s")
            choice.applyTo(request)

            runOnUi { statusText.text = "[$jobNumber/$totalJobs] Starting ${hostLabel(url)}" }
            YoutubeDL.getInstance().execute(request, processId, true) { progress, etaInSeconds, line ->
                runOnUi {
                    val finished = finishedJobs.get()
                    if (progress in 0f..100f && totalJobs > 0) {
                        val overall = ((finished.toFloat() + progress / 100f) / totalJobs.toFloat() * 100f).toInt()
                        progressBar.progress = overall.coerceIn(0, 99)
                    }
                    val eta = if (etaInSeconds > 0) " ETA ${formatDuration(etaInSeconds)}" else ""
                    val message = line.takeIf { it.isNotBlank() } ?: "Downloading..."
                    statusText.text = "[$jobNumber/$totalJobs] $message$eta"
                }
            }

            markJobFinished()
        } catch (canceled: YoutubeDL.CanceledException) {
            markJobFinished(canceled = true)
        } catch (error: Throwable) {
            lastError.set(cleanMessage(error))
            markJobFinished(failed = true)
        } finally {
            currentProcessIds.remove(processId)
        }
    }

    private fun cancelDownloads() {
        isDownloading = false
        setWorking(true, "Canceling downloads...")
        currentProcessIds.forEach { YoutubeDL.getInstance().destroyProcessById(it) }
        val queued = downloadExecutor?.shutdownNow()?.size ?: 0
        if (queued > 0) {
            canceledJobs.addAndGet(queued)
            finishedJobs.addAndGet(queued)
        }
        if (currentProcessIds.isEmpty()) {
            finishBatchIfDone()
        }
    }

    private fun markJobFinished(failed: Boolean = false, canceled: Boolean = false) {
        if (failed) failedJobs.incrementAndGet()
        if (canceled) canceledJobs.incrementAndGet()
        val done = finishedJobs.incrementAndGet()
        runOnUi {
            if (totalJobs > 0) {
                progressBar.progress = (done * 100 / totalJobs).coerceIn(0, 100)
            }
            statusText.text = "$done/$totalJobs finished"
            finishBatchIfDone()
        }
    }

    private fun finishBatchIfDone() {
        if (totalJobs <= 0 || finishedJobs.get() < totalJobs) return

        isDownloading = false
        currentProcessIds.clear()
        downloadExecutor = null
        progressBar.progress = 100
        setDownloadUi(running = false)

        val failed = failedJobs.get()
        val canceled = canceledJobs.get()
        val completed = totalJobs - failed - canceled
        val summary = if (failed == 0 && canceled == 0) {
            "All downloads saved to ${downloadDirectory().absolutePath}"
        } else {
            val error = lastError.get()?.let { ": $it" } ?: ""
            "Finished: $completed done, $failed failed, $canceled canceled$error"
        }
        setWorking(false, summary)
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

    private fun normalizedUrls(): List<String>? {
        val text = urlInput.text.toString().trim()
        if (text.isBlank()) {
            toast("Paste one or more video links first")
            return null
        }
        val urls = extractUrlCandidates(text).mapNotNull { normalizedUrl(it) }.distinct()
        if (urls.isEmpty()) {
            toast("Use X, YouTube, or Bilibili links")
            return null
        }
        hideKeyboard()
        return urls
    }

    private fun extractUrlCandidates(text: String): List<String> {
        val detected = Regex("""https?://[^\s,;]+""", RegexOption.IGNORE_CASE)
            .findAll(text)
            .map { it.value.cleanedUrlCandidate() }
            .toList()
        if (detected.isNotEmpty()) return detected

        return text
            .split(Regex("""\s+"""))
            .map { it.cleanedUrlCandidate() }
            .filter { it.startsWith("http://", ignoreCase = true) || it.startsWith("https://", ignoreCase = true) }
    }

    private fun normalizedUrl(raw: String): String? {
        val url = raw.cleanedUrlCandidate()
        val host = try {
            URI(url).host?.lowercase(Locale.US)?.removePrefix("www.")
        } catch (_: Exception) {
            null
        }
        if (host == null || supportedHosts.none { host == it || host.endsWith(".$it") }) {
            return null
        }
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

    private fun setDownloadUi(running: Boolean) {
        downloadButton.text = if (running) "Cancel all" else "Download queue"
        parseButton.isEnabled = !running
        updateButton.isEnabled = !running && engineReady
        qualitySpinner.isEnabled = !running
        concurrencySpinner.isEnabled = !running
        urlInput.isEnabled = !running
    }

    private fun setWorking(working: Boolean, message: String) {
        statusText.text = message
        parseButton.isEnabled = engineReady && !working && !isDownloading
        downloadButton.isEnabled = engineReady && (!working || isDownloading)
        updateButton.isEnabled = engineReady && !working && !isDownloading
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

    private fun hostLabel(url: String): String {
        return try {
            URI(url).host?.removePrefix("www.") ?: "video"
        } catch (_: Exception) {
            "video"
        }
    }

    private fun String.cleanedUrlCandidate(): String {
        return trim().trimEnd('.', ',', ';', ')', ']', '}', '>', '"', '\'')
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
        private const val MAX_CONCURRENCY = 5
        private val SURFACE = Color.rgb(247, 245, 240)
        private val INK = Color.rgb(23, 23, 23)
        private val MUTED = Color.rgb(103, 99, 91)
        private val ACCENT = Color.rgb(14, 143, 114)
    }
}
