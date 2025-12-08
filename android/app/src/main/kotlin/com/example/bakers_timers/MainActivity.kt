package com.example.bakers_timers

import android.content.Intent
import android.media.RingtoneManager
import android.net.Uri
import java.io.File
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall

class MainActivity: FlutterActivity() {
	private var pendingResult: MethodChannel.Result? = null
	private val CHANNEL = "bakers_timers/ringtone"
	private val REQUEST_CODE_RINGTONE = 1999

	override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
			if (call.method == "pickRingtone") {
				if (pendingResult != null) {
					result.error("ALREADY_ACTIVE", "Ringtone picker already active", null)
					return@setMethodCallHandler
				}
				pendingResult = result
				val intent = Intent(RingtoneManager.ACTION_RINGTONE_PICKER)
				intent.putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, RingtoneManager.TYPE_ALARM or RingtoneManager.TYPE_RINGTONE or RingtoneManager.TYPE_NOTIFICATION)
				intent.putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, false)
				intent.putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
				val existingUriString = call.argument<String>("existingUri")
				if (existingUriString != null) {
					try {
						val existing = Uri.parse(existingUriString)
						intent.putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, existing)
					} catch (_: Exception) {}
				}
				startActivityForResult(intent, REQUEST_CODE_RINGTONE)
			} else if (call.method == "copyRingtoneToCache") {
				val uriStr = call.argument<String>("uri")
				if (uriStr == null) {
					result.success(null)
					return@setMethodCallHandler
				}
				try {
					val u = Uri.parse(uriStr)
					val inputStream = contentResolver.openInputStream(u)
					if (inputStream == null) { result.success(null); return@setMethodCallHandler }
					val outFile = File(cacheDir, "bakers_ringtone_${System.currentTimeMillis()}.dat")
					outFile.outputStream().use { outs ->
						inputStream.use { ins ->
							ins.copyTo(outs)
						}
					}
					result.success(outFile.absolutePath)
				} catch (e: Exception) {
					result.error("COPY_FAILED", e.message, null)
				}
			} else {
				result.notImplemented()
			}
		}
	}

	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
		super.onActivityResult(requestCode, resultCode, data)
		if (requestCode == REQUEST_CODE_RINGTONE) {
			val res = pendingResult
			pendingResult = null
			if (res == null) return
			if (resultCode == RESULT_OK) {
				val uri: Uri? = data?.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
				if (uri != null) {
					res.success(uri.toString())
				} else {
					res.success(null)
				}
			} else {
				res.success(null)
			}
		}
	}
}
