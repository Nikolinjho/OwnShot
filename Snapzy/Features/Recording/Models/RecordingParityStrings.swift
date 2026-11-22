//
//  RecordingParityStrings.swift
//  Snapzy
//
//  Строки записи экрана, добавленные для паритета с эталоном.
//  Ключи с префиксом recording. попадают в таблицу Recording.
//

import Foundation

extension L10n {
  nonisolated enum RecordingParity {
    // MARK: - Пункты меню источников

    static let doNotRecordCamera = string(
      "recording.parity.do-not-record-camera",
      defaultValue: "Don't Record Camera",
      comment: "Camera menu option to disable camera capture"
    )
    static let doNotRecordMicrophone = string(
      "recording.parity.do-not-record-microphone",
      defaultValue: "Do Not Record Microphone",
      comment: "Microphone menu option to disable microphone capture"
    )

    // MARK: - Камера

    static let cameraShapeVertical = string(
      "recording.parity.camera.shape.vertical", defaultValue: "Vertical", comment: "Camera overlay shape option"
    )
    static let cameraSizeHuge = string(
      "recording.parity.camera.size.huge", defaultValue: "Huge", comment: "Camera overlay size option"
    )

    // MARK: - Разрешения

    static let microphoneNoAccessTitle = string(
      "recording.parity.microphone-no-access-title",
      defaultValue: "OwnShot does not have access to the microphone",
      comment: "Alert title when microphone permission is missing"
    )
    static let microphoneNoAccessMessage = string(
      "recording.parity.microphone-no-access-message",
      defaultValue: "Please give OwnShot access to your microphone in order to record your voice or system audio.",
      comment: "Alert message when microphone permission is missing"
    )
    static let cameraNoAccessTitle = string(
      "recording.parity.camera-no-access-title",
      defaultValue: "OwnShot does not have access to the camera",
      comment: "Alert title when camera permission is missing"
    )
    static let cameraNoAccessMessage = string(
      "recording.parity.camera-no-access-message",
      defaultValue: "Please give OwnShot access to your camera in order to record. You will need to relaunch OwnShot after granting permission.",
      comment: "Alert message when camera permission is missing"
    )

    // MARK: - Ошибки старта и остановки

    static let startErrorTitle = string(
      "recording.parity.start-error-title",
      defaultValue: "An error occurred while starting screen recording.",
      comment: "Alert title when screen recording fails to start"
    )
    static let startErrorMessage = string(
      "recording.parity.start-error-message",
      defaultValue: "This may be caused by DRM-protected content playing in the background. Please try restarting your system if the issue persists.",
      comment: "Alert message when screen recording fails to start"
    )
    static let stoppedTitle = string(
      "recording.parity.stopped-title",
      defaultValue: "Recording Stopped",
      comment: "Alert title when the recording stopped on its own"
    )
    static let stoppedUnexpectedly = string(
      "recording.parity.stopped-unexpectedly",
      defaultValue: "Screen Recording stopped unexpectedly.",
      comment: "Alert message when the capture stream stopped by itself"
    )

    // MARK: - Диск

    static let diskLowTitle = string(
      "recording.parity.disk-low-title",
      defaultValue: "Your free disk space is low.",
      comment: "Alert title before recording when free disk space is low"
    )
    static let diskLowMessage = string(
      "recording.parity.disk-low-message",
      defaultValue: "The recording might stop unexpectedly and you may lose the file.",
      comment: "Alert message before recording when free disk space is low"
    )
    static let dontWarnAgain = string(
      "recording.parity.dont-warn-again",
      defaultValue: "Don't warn me again",
      comment: "Suppression checkbox for recording warnings"
    )
    static let diskFullTitle = string(
      "recording.parity.disk-full-title",
      defaultValue: "Recording stopped because your disk is almost full.",
      comment: "Alert title when the recording was stopped because of low disk space"
    )
    static let diskFullMessage = string(
      "recording.parity.disk-full-message",
      defaultValue: "The recording was stopped to prevent data loss. Free up some disk space before recording again.",
      comment: "Alert message when the recording was stopped because of low disk space"
    )

    // MARK: - Микрофон

    static let noMicrophoneTitle = string(
      "recording.parity.no-microphone-title",
      defaultValue: "No microphone selected",
      comment: "Alert title when the camera is on but the microphone is off"
    )
    static let noMicrophoneMessage = string(
      "recording.parity.no-microphone-message",
      defaultValue: "You’ve enabled camera recording, but no microphone is selected. Select a mic to include sound in your video.",
      comment: "Alert message when the camera is on but the microphone is off"
    )
    static let dontRecordAudio = string(
      "recording.parity.dont-record-audio",
      defaultValue: "Don't Record Audio",
      comment: "Button that starts the recording without a microphone"
    )
    static let showPreferences = string(
      "recording.parity.show-preferences",
      defaultValue: "Show preferences",
      comment: "Button that returns to source selection instead of starting the recording"
    )
    static let dontAskAgain = string(
      "recording.parity.dont-ask-again",
      defaultValue: "Don’t ask again",
      comment: "Suppression checkbox for the no microphone alert"
    )
    static let lidClosedMessage = string(
      "recording.parity.lid-closed-message",
      defaultValue: "The built-in microphone cannot be used when the MacBook lid is closed.",
      comment: "Alert shown when the built-in microphone is selected while the lid is closed"
    )
    static let microphoneMutedTitle = string(
      "recording.parity.microphone-muted-title",
      defaultValue: "Microphone is muted",
      comment: "Alert title when the selected microphone looks muted"
    )
    static let microphoneMutedMessage = string(
      "recording.parity.microphone-muted-message",
      defaultValue: "It appears that your microphone might be muted. Would you like to continue recording?",
      comment: "Alert message when the selected microphone looks muted"
    )
    static let microphoneDisconnectedTitle = string(
      "recording.parity.microphone-disconnected-title",
      defaultValue: "Microphone Disconnected",
      comment: "Alert title when the microphone disconnects during a recording"
    )
    static let microphoneDisconnectedMessage = string(
      "recording.parity.microphone-disconnected-message",
      defaultValue: "Your microphone has been disconnected during the recording. Do you want to continue recording without audio or stop the recording?",
      comment: "Alert message when the microphone disconnects during a recording"
    )
    static let continueWithoutAudio = string(
      "recording.parity.continue-without-audio",
      defaultValue: "Continue Without Audio",
      comment: "Button that keeps recording after the microphone disconnected"
    )
    static let stopRecording = string(
      "recording.parity.stop-recording",
      defaultValue: "Stop Recording",
      comment: "Button that stops the recording after the microphone disconnected"
    )
    static let continueRecording = string(
      "recording.parity.continue-recording",
      defaultValue: "Continue Recording",
      comment: "Button that starts the recording despite the warning"
    )

    // MARK: - Системный звук

    static let audioRecordingFailedTitle = string(
      "recording.parity.audio-recording-failed-title",
      defaultValue: "Audio Recording Failed",
      comment: "Alert title when system audio stops being captured during a recording"
    )
    static let audioRecordingFailedMessage = string(
      "recording.parity.audio-recording-failed-message",
      defaultValue: "Unable to capture system audio. Do you want to continue recording without audio or stop the recording?",
      comment: "Alert message when system audio stops being captured during a recording"
    )

    // MARK: - Сведение дорожек

    static let mergingAudio = string(
      "recording.parity.merging-audio",
      defaultValue: "Merging audio...",
      comment: "Progress title while the microphone and system audio tracks are merged"
    )
    static let stopProcessingTitle = string(
      "recording.parity.stop-processing-title",
      defaultValue: "Are you sure you want to stop the processing?",
      comment: "Confirmation title when the user cancels merging audio tracks"
    )
    static let stopProcessingMessage = string(
      "recording.parity.stop-processing-message",
      defaultValue: "The audio tracks will not be merged. Your recording will be saved with the tracks separate.",
      comment: "Confirmation message when the user cancels merging audio tracks"
    )
    static let stopProcessing = string(
      "recording.parity.stop-processing",
      defaultValue: "Stop Processing",
      comment: "Button that stops merging audio tracks"
    )
    static let continueProcessing = string(
      "recording.parity.continue-processing",
      defaultValue: "Continue",
      comment: "Button that keeps merging audio tracks"
    )
    static let mergeFailedTitle = string(
      "recording.parity.merge-failed-title",
      defaultValue: "Can't merge audio tracks",
      comment: "Alert title when merging the audio tracks failed"
    )
    static let mergeFailedMessage = string(
      "recording.parity.merge-failed-message",
      defaultValue: "Your recording has been saved and is not affected — the microphone and system audio simply remain on separate tracks.",
      comment: "Alert message when merging the audio tracks failed"
    )
    static let mergeDiskLowMessage = string(
      "recording.parity.merge-disk-low-message",
      defaultValue: "Your free disk space is too low. Your recording has been saved and is not affected — the microphone and system audio simply remain on separate tracks.",
      comment: "Alert message when the audio tracks were not merged because of low disk space"
    )

    // MARK: - Audio Mixer

    static let audioMixerTitle = string(
      "recording.parity.audio-mixer.title",
      defaultValue: "Audio Mixer",
      comment: "Title of the window that merges microphone and system audio with custom volumes"
    )
    static let audioMixerMenuItem = string(
      "recording.parity.audio-mixer.menu-item",
      defaultValue: "Adjust Audio Volume…",
      comment: "Quick Access card menu item that opens the audio mixer for a recording with two audio tracks"
    )
    static let audioMixerPrompt = string(
      "recording.parity.audio-mixer.prompt",
      defaultValue: "Merge audio to adjust the volume of each track separately:",
      comment: "Explanation above the audio mixer volume sliders"
    )
    static let audioMixerMicrophoneVolume = string(
      "recording.parity.audio-mixer.microphone-volume",
      defaultValue: "Microphone volume:",
      comment: "Label of the microphone volume slider in the audio mixer"
    )
    static let audioMixerSystemAudioVolume = string(
      "recording.parity.audio-mixer.system-audio-volume",
      defaultValue: "System audio volume:",
      comment: "Label of the system audio volume slider in the audio mixer"
    )
    static let audioMixerMerge = string(
      "recording.parity.audio-mixer.merge",
      defaultValue: "Merge Audio",
      comment: "Button that merges the audio tracks with the chosen volumes"
    )
    static let audioMixerKeepSeparateTitle = string(
      "recording.parity.audio-mixer.keep-separate-title",
      defaultValue: "Do you want to continue?",
      comment: "Confirmation title when the audio mixer is closed without merging"
    )
    static let audioMixerKeepSeparateMessage = string(
      "recording.parity.audio-mixer.keep-separate-message",
      defaultValue: "Microphone and system audio will remain on separate tracks.",
      comment: "Confirmation message when the audio mixer is closed without merging"
    )

    // MARK: - GIF

    static let stopConversionTitle = string(
      "recording.parity.stop-conversion-title",
      defaultValue: "Are you sure you want to stop the conversion?",
      comment: "Confirmation title when the user cancels GIF conversion"
    )
    static let stopConversionMessage = string(
      "recording.parity.stop-conversion-message",
      defaultValue: "You can delete the recording or stop the GIF conversion and save it as a video instead.",
      comment: "Confirmation message when the user cancels GIF conversion"
    )
    static let saveAsVideo = string(
      "recording.parity.save-as-video",
      defaultValue: "Save as Video",
      comment: "Button that stops GIF conversion and keeps the video"
    )
    static let deleteRecording = string(
      "recording.parity.delete-recording",
      defaultValue: "Delete Recording",
      comment: "Button that stops GIF conversion and deletes the recording"
    )
    static let continueConversion = string(
      "recording.parity.continue-conversion",
      defaultValue: "Continue Converting",
      comment: "Button that keeps converting the recording to GIF"
    )

    // MARK: - Сохранение и восстановление

    static let saveFailedTitle = string(
      "recording.parity.save-failed-title",
      defaultValue: "Something went wrong saving your file.",
      comment: "Alert title when the recording could not be saved"
    )
    static let recoveredTitle = string(
      "recording.parity.recovered-title",
      defaultValue: "OwnShot quit unexpectedly",
      comment: "Notification title after an unfinished recording was recovered on launch"
    )
    static let recoveredMessage = string(
      "recording.parity.recovered-message",
      defaultValue: "Your screen recording has been successfully recovered.",
      comment: "Notification body after an unfinished recording was recovered on launch"
    )

    // MARK: - Do Not Disturb

    static let focusSetupTitle = string(
      "recording.parity.focus-setup-title",
      defaultValue: "Set up \"Do Not Disturb\" while recording",
      comment: "Alert title when the Focus shortcuts are not installed yet"
    )
    static let focusSetupMessage = string(
      "recording.parity.focus-setup-message",
      defaultValue: "OwnShot turns on Do Not Disturb with three macOS Shortcuts. Add them to continue. Your current Focus is preserved.",
      comment: "Alert message when the Focus shortcuts are not installed yet"
    )
    static let focusSetupButton = string(
      "recording.parity.focus-setup-button",
      defaultValue: "Set Up…",
      comment: "Button that opens the Focus shortcuts for installation"
    )

    // MARK: - Выбор области

    static func dragToRecordHint(windowShortcut: String?) -> String {
      guard let windowShortcut else { return dragToRecordOnly }
      return format(
        "recording.parity.drag-to-record-hint",
        defaultValue: "Drag to record a part of the screen. Press %@ to select a window.",
        comment: "Centered hint on the recording area selection. %@ is the window selection key, Space by default.",
        windowShortcut
      )
    }
    static let dragToRecordOnly = string(
      "recording.parity.drag-to-record-only",
      defaultValue: "Drag to record a part of the screen.",
      comment: "Centered hint on the recording area selection when window selection is unavailable"
    )

    // MARK: - Настройки: клики

    static let size = string("recording.parity.size", defaultValue: "Size", comment: "Overlay size slider")
    static let color = string("recording.parity.color", defaultValue: "Color", comment: "Click highlight color picker")
    static let style = string("recording.parity.style", defaultValue: "Style", comment: "Click highlight style picker")
    static let animateClicks = string(
      "recording.parity.animate-clicks", defaultValue: "Animate clicks", comment: "Click highlight animation toggle"
    )
    static let clickToPreview = string(
      "recording.parity.click-to-preview", defaultValue: "Click here to preview", comment: "Click highlight preview area"
    )
    static let done = string("recording.parity.done", defaultValue: "Done", comment: "Closes the options sheet")
    static let preview = string("recording.parity.preview", defaultValue: "Preview", comment: "Shows a keystroke preview")
    static let systemAccentColor = string(
      "recording.parity.color.system", defaultValue: "System Accent color", comment: "Click color option"
    )
    static let blue = string("recording.parity.color.blue", defaultValue: "Blue", comment: "Click color option")
    static let purple = string("recording.parity.color.purple", defaultValue: "Purple", comment: "Click color option")
    static let pink = string("recording.parity.color.pink", defaultValue: "Pink", comment: "Click color option")
    static let red = string("recording.parity.color.red", defaultValue: "Red", comment: "Click color option")
    static let orange = string("recording.parity.color.orange", defaultValue: "Orange", comment: "Click color option")
    static let yellow = string("recording.parity.color.yellow", defaultValue: "Yellow", comment: "Click color option")
    static let green = string("recording.parity.color.green", defaultValue: "Green", comment: "Click color option")
    static let customColor = string(
      "recording.parity.color.custom", defaultValue: "Custom", comment: "Click color option for a previously chosen custom color"
    )
    static let gray = string("recording.parity.color.gray", defaultValue: "Gray", comment: "Click color option")
    static let outline = string("recording.parity.style.outline", defaultValue: "Outline", comment: "Click style option")
    static let filled = string("recording.parity.style.filled", defaultValue: "Filled", comment: "Click style option")

    // MARK: - Настройки: клавиши

    static let appearance = string(
      "recording.parity.appearance", defaultValue: "Appearance", comment: "Keystroke badge appearance picker"
    )
    static let dark = string("recording.parity.appearance.dark", defaultValue: "Dark", comment: "Keystroke appearance")
    static let light = string("recording.parity.appearance.light", defaultValue: "Light", comment: "Keystroke appearance")
    static let position = string("recording.parity.position", defaultValue: "Position", comment: "Keystroke position picker")
    static let keys = string("recording.parity.keys", defaultValue: "Keys", comment: "Keystroke filter picker")
    static let showAllKeys = string(
      "recording.parity.keys.all", defaultValue: "Show all keys", comment: "Keystroke filter option"
    )
    static let showOnlyCommandKeys = string(
      "recording.parity.keys.command", defaultValue: "Show only command keys", comment: "Keystroke filter option"
    )
    static let blurBackground = string(
      "recording.parity.blur-background", defaultValue: "Blur background", comment: "Keystroke badge blur toggle"
    )
    static let topLeft = string("recording.parity.position.top-left", defaultValue: "Top-Left", comment: "Keystroke position")
    static let topCenter = string("recording.parity.position.top-center", defaultValue: "Top-Center", comment: "Keystroke position")
    static let topRight = string("recording.parity.position.top-right", defaultValue: "Top-Right", comment: "Keystroke position")
    static let bottomLeft = string("recording.parity.position.bottom-left", defaultValue: "Bottom-Left", comment: "Keystroke position")
    static let bottomCenter = string(
      "recording.parity.position.bottom-center", defaultValue: "Bottom-Center", comment: "Keystroke position"
    )
    static let bottomRight = string(
      "recording.parity.position.bottom-right", defaultValue: "Bottom-Right", comment: "Keystroke position"
    )
  }
}
