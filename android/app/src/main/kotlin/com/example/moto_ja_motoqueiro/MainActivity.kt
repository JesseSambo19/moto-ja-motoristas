package com.example.moto_ja_motoqueiro

import android.speech.tts.TextToSpeech
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
  private var textToSpeech: TextToSpeech? = null
  private var ttsReady = false
  private var ttsFailed = false
  private var pendingSpeech: String? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    textToSpeech = TextToSpeech(this) { status ->
      if (status == TextToSpeech.SUCCESS) {
        var languageStatus = textToSpeech?.setLanguage(Locale("pt", "PT")) ?: TextToSpeech.LANG_NOT_SUPPORTED
        if (languageStatus == TextToSpeech.LANG_MISSING_DATA || languageStatus == TextToSpeech.LANG_NOT_SUPPORTED) {
          languageStatus = textToSpeech?.setLanguage(Locale("pt", "BR")) ?: TextToSpeech.LANG_NOT_SUPPORTED
        }
        ttsReady = languageStatus >= TextToSpeech.LANG_AVAILABLE
        ttsFailed = !ttsReady
        if (ttsReady) {
          pendingSpeech?.let { textToSpeech?.speak(it, TextToSpeech.QUEUE_FLUSH, null, "motoja-navigation") }
        }
        pendingSpeech = null
      } else {
        ttsFailed = true
      }
    }

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.motoja.driver/voice-guidance")
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "speak" -> {
            val text = call.argument<String>("text")
            if (text.isNullOrBlank()) {
              result.error("empty_text", "Speech text was empty", null)
            } else if (ttsReady) {
              textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "motoja-navigation")
              result.success(true)
            } else if (ttsFailed) {
              result.error("tts_unavailable", "Install a Portuguese text-to-speech voice on this device.", null)
            } else {
              pendingSpeech = text
              result.success(true)
            }
          }
          "stop" -> {
            pendingSpeech = null
            textToSpeech?.stop()
            result.success(true)
          }
          else -> result.notImplemented()
        }
      }
  }

  override fun onDestroy() {
    textToSpeech?.stop()
    textToSpeech?.shutdown()
    textToSpeech = null
    super.onDestroy()
  }
}
