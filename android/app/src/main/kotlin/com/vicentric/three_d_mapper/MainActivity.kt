package com.vicentric.three_d_mapper

import java.io.File
import android.speech.tts.TextToSpeech
import java.util.Locale
import android.content.Intent
import android.app.Activity
import android.provider.MediaStore
import androidx.core.content.FileProvider
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class MainActivity : FlutterActivity() {
    private var speech: TextToSpeech? = null
    private var speechReady = false
    private var sink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null
    var recognitionView: RecognitionCameraView? = null
    private var captureResult: MethodChannel.Result? = null
    private var captureFile: File? = null
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        speech = TextToSpeech(this) { status ->
            runOnUiThread {
                val language = speech?.setLanguage(Locale.ENGLISH)
                val offlineVoice = speech?.voices?.firstOrNull { !it.isNetworkConnectionRequired && it.locale.language == "en" }
                if (offlineVoice != null) speech?.voice = offlineVoice
                speechReady = status == TextToSpeech.SUCCESS && language != null && language != TextToSpeech.LANG_MISSING_DATA && language != TextToSpeech.LANG_NOT_SUPPORTED && offlineVoice != null
            }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, "three_d_mapper/recognition/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
                override fun onCancel(arguments: Any?) { sink = null }
            })
        MethodChannel(engine.dartExecutor.binaryMessenger, "three_d_mapper/recognition")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> {
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                            result.success(true)
                        } else if (permissionResult != null) {
                            result.error("permission_pending", "A camera permission request is already open", null)
                        } else {
                            permissionResult = result
                            requestPermissions(arrayOf(Manifest.permission.CAMERA), 4401)
                        }
                    }
                    "speakRoutePreview" -> {
                        val text = call.argument<String>("text") ?: ""
                        if (!speechReady) result.error("speech_unavailable", "Text-to-speech is not ready. Install offline English voice data and try again.", null)
                        else if (text.isBlank() || text.length > TextToSpeech.getMaxSpeechInputLength()) result.error("speech_text", "Route preview is too long for one reading. Read the individual instructions with your screen reader.", null)
                        else if (speech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "route-preview") == TextToSpeech.ERROR) result.error("speech_failed", "Could not speak the route preview", null)
                        else result.success(null)
                    }
                    "stopSpeech" -> { speech?.stop(); result.success(null) }
                    "captureLandmarkPhoto" -> capturePhoto(result)
                    "discardLandmarkCapture" -> {
                        try {
                            val candidate=File(call.argument<String>("path") ?: error("Missing capture path")).canonicalFile
                            val directory=File(cacheDir,"landmark_capture").canonicalFile
                            check(candidate.parentFile==directory && candidate.name.startsWith("landmark-") && candidate.extension=="jpg") { "Not an owned temporary capture" }
                            if(candidate.exists())candidate.delete()
                            result.success(null)
                        } catch(e:Exception){result.error("capture_cleanup",e.message,null)}
                    }
                    "saveRecognitionSample" -> {
                        val view = recognitionView
                        if (view == null) result.error("sample_unavailable", "Open the camera recognition test first", null)
                        else view.saveSample(call.argument<String>("expected_label_id"), result)
                    }
                    "discardRecognitionSample" -> {
                        try { RecognitionSample.discard(cacheDir, call.argument<String>("path") ?: error("Missing sample path")); result.success(null) }
                        catch (error: Exception) { result.error("sample_cleanup", error.message, null) }
                    }
                    "reset" -> { recognitionView?.resetEvidence(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        engine.platformViewsController.registry.registerViewFactory("three_d_mapper/recognition-camera",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: android.content.Context, viewId: Int, args: Any?): PlatformView {
                    val data = args as? Map<*, *> ?: emptyMap<Any, Any>()
                    val references = (data["references"] as? List<*>)?.mapNotNull { it as? Map<*, *> } ?: emptyList()
                    return RecognitionCameraView(this@MainActivity, context, references, data["engine"] != "orb-sift").also { recognitionView = it }
                }
            })
    }
    fun emit(view: RecognitionCameraView, data: Map<String, Any?>) {
        runOnUiThread { if (recognitionView === view) sink?.success(data) }
    }
    private fun capturePhoto(result: MethodChannel.Result) {
        if(captureResult!=null){result.error("capture_pending","Another photo capture is open",null);return}
        if(recognitionView!=null){result.error("camera_busy","Close the recognition test before taking admin photos",null);return}
        if(ContextCompat.checkSelfPermission(this,Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED){result.error("camera_permission","Allow camera permission first",null);return}
        try{
            val directory=File(cacheDir,"landmark_capture").apply{mkdirs()}
            val file=File.createTempFile("landmark-",".jpg",directory)
            val uri=FileProvider.getUriForFile(this,"$packageName.mapper.photos",file)
            val intent=Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                putExtra(MediaStore.EXTRA_OUTPUT,uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                clipData=android.content.ClipData.newRawUri("Landmark photo",uri)
            }
            if(intent.resolveActivity(packageManager)==null){file.delete();error("No camera app is available; choose an existing photo instead")}
            captureResult=result;captureFile=file
            startActivityForResult(intent,4601)
        }catch(e:Exception){captureResult=null;captureFile?.delete();captureFile=null;result.error("capture",e.message,null)}
    }
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?){
        super.onActivityResult(requestCode,resultCode,data)
        if(requestCode!=4601)return
        val result=captureResult;val file=captureFile;captureResult=null;captureFile=null
        if(resultCode==Activity.RESULT_OK && file!=null && file.exists() && file.length()>0){result?.success(file.absolutePath)}
        else{file?.delete();result?.success(null)}
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4401) {
            permissionResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            permissionResult = null
        }
    }
    override fun onPause() { speech?.stop(); super.onPause() }
    override fun onDestroy() {
        permissionResult?.error("closed", "Camera request was interrupted", null)
        permissionResult = null
        captureResult?.error("closed","Photo capture was interrupted",null)
        captureResult=null;captureFile?.delete();captureFile=null
        speech?.stop(); speech?.shutdown(); speech=null; speechReady=false
        super.onDestroy()
    }
}
