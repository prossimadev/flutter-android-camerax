// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import XCTest

@testable import camera_avfoundation

private class FakeMediaSettingsAVWrapper: FLTCamMediaSettingsAVWrapper {
  let inputMock: MockAssetWriterInput

  init(inputMock: MockAssetWriterInput) {
    self.inputMock = inputMock
  }

  override func lockDevice(_ captureDevice: FLTCaptureDevice) throws {
    // No-op.
  }

  override func unlockDevice(_ captureDevice: FLTCaptureDevice) {
    // No-op.
  }

  override func beginConfiguration(for videoCaptureSession: FLTCaptureSession) {
    // No-op.
  }

  override func commitConfiguration(for videoCaptureSession: FLTCaptureSession) {
    // No-op.
  }

  override func setMinFrameDuration(_ duration: CMTime, on captureDevice: FLTCaptureDevice) {
    // No-op.
  }

  override func setMaxFrameDuration(_ duration: CMTime, on captureDevice: FLTCaptureDevice) {
    // No-op.
  }

  override func assetWriterAudioInput(withOutputSettings outputSettings: [String: Any]?)
    -> FLTAssetWriterInput
  {
    return inputMock
  }

  override func assetWriterVideoInput(withOutputSettings outputSettings: [String: Any]?)
    -> FLTAssetWriterInput
  {
    return inputMock
  }

  override func addInput(_ writerInput: FLTAssetWriterInput, to writer: FLTAssetWriter) {
    // No-op.
  }

  override func recommendedVideoSettingsForAssetWriter(
    withFileType fileType: AVFileType, for output: FLTCaptureVideoDataOutput
  ) -> [String: Any]? {
    return [:]
  }
}

/// Includes test cases related to sample buffer handling for FLTCam class.
final class CameraSampleBufferTests: XCTestCase {
  private func createCamera() -> (
    FLTCam,
    MockAssetWriter,
    MockAssetWriterInputPixelBufferAdaptor,
    MockAssetWriterInput,
    MockCaptureConnection
  ) {
    let assetWriter = MockAssetWriter()
    let adaptor = MockAssetWriterInputPixelBufferAdaptor()
    let input = MockAssetWriterInput()

    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.mediaSettings = FCPPlatformMediaSettings.make(
      with: .medium,
      framesPerSecond: nil,
      videoBitrate: nil,
      audioBitrate: nil,
      enableAudio: true)
    configuration.mediaSettingsWrapper = FakeMediaSettingsAVWrapper(inputMock: input)

    configuration.assetWriterFactory = { url, fileType, error in
      return assetWriter
    }
    configuration.inputPixelBufferAdaptorFactory = { input, settings in
      return adaptor
    }

    return (
      FLTCam(configuration: configuration, error: nil), assetWriter, adaptor, input,
      MockCaptureConnection()
    )
  }

  func testSampleBufferCallbackQueueMustBeCaptureSessionQueue() {
    let captureSessionQueue = DispatchQueue(label: "testing")
    let camera = CameraTestUtils.createCameraWithCaptureSessionQueue(captureSessionQueue)
    XCTAssertEqual(
      captureSessionQueue, camera.captureVideoOutput.avOutput.sampleBufferCallbackQueue,
      "Sample buffer callback queue must be the capture session queue.")
  }

  func testCopyPixelBuffer() {
    let (camera, _, _, _, connectionMock) = createCamera()
    let capturedSampleBuffer = CameraTestUtils.createTestSampleBuffer()
    let capturedPixelBuffer = CMSampleBufferGetImageBuffer(capturedSampleBuffer)!
    // Mimic sample buffer callback when captured a new video sample.
    camera.captureOutput(
      camera.captureVideoOutput.avOutput, didOutputSampleBuffer: capturedSampleBuffer,
      from: connectionMock)
    let deliveredPixelBuffer = camera.copyPixelBuffer()?.takeRetainedValue()
    XCTAssertEqual(
      deliveredPixelBuffer, capturedPixelBuffer,
      "FLTCam must deliver the latest captured pixel buffer to copyPixelBuffer API.")
  }

  func testDidOutputSampleBuffer_mustNotChangeSampleBufferRetainCountAfterPauseResumeRecording() {
    let (camera, _, _, _, connectionMock) = createCamera()
    let sampleBuffer = CameraTestUtils.createTestSampleBuffer()

    let initialRetainCount = CFGetRetainCount(sampleBuffer)

    // Pause then resume the recording.
    camera.startVideoRecording(completion: { error in }, messengerForStreaming: nil)
    camera.pauseVideoRecording()
    camera.resumeVideoRecording()

    camera.captureOutput(
      camera.captureVideoOutput.avOutput, didOutputSampleBuffer: sampleBuffer, from: connectionMock)

    let finalRetainCount = CFGetRetainCount(sampleBuffer)
    XCTAssertEqual(
      finalRetainCount, initialRetainCount,
      "didOutputSampleBuffer must not change the sample buffer retain count after pause resume recording."
    )
  }

  func testDidOutputSampleBufferIgnoreAudioSamplesBeforeVideoSamples() {
    let (camera, writerMock, adaptorMock, inputMock, connectionMock) = createCamera()
    var status = AVAssetWriter.Status.unknown
    writerMock.startWritingStub = {
      status = .writing
      return true
    }
    writerMock.statusStub = {
      return status
    }

    let videoSample = CameraTestUtils.createTestSampleBuffer()
    let audioSample = CameraTestUtils.createTestAudioSampleBuffer()

    var writtenSamples: [String] = []
    adaptorMock.appendStub = { buffer, time in
      writtenSamples.append("video")
      return true
    }
    inputMock.readyForMoreMediaData = true
    inputMock.appendStub = { buffer in
      writtenSamples.append("audio")
      return true
    }

    camera.startVideoRecording(completion: { error in }, messengerForStreaming: nil)
    camera.captureOutput(nil, didOutputSampleBuffer: audioSample, from: connectionMock)
    camera.captureOutput(nil, didOutputSampleBuffer: audioSample, from: connectionMock)
    camera.captureOutput(
      camera.captureVideoOutput.avOutput, didOutputSampleBuffer: videoSample, from: connectionMock)
    camera.captureOutput(nil, didOutputSampleBuffer: audioSample, from: connectionMock)

    let expectedSamples = ["video", "audio"]
    XCTAssertEqual(writtenSamples, expectedSamples, "First appended sample must be video.")
  }

  func testDidOutputSampleBufferSampleTimesMustBeNumericAfterPauseResume() {
    let (camera, writerMock, adaptorMock, inputMock, connectionMock) = createCamera()

    let videoSample = CameraTestUtils.createTestSampleBuffer()
    let audioSample = CameraTestUtils.createTestAudioSampleBuffer()

    var status = AVAssetWriter.Status.unknown
    writerMock.startWritingStub = {
      status = .writing
      return true
    }
    writerMock.statusStub = {
      return status
    }

    var videoAppended = false
    adaptorMock.appendStub = { buffer, time in
      XCTAssert(CMTIME_IS_NUMERIC(time))
      videoAppended = true
      return true
    }

    var audioAppended = false
    inputMock.readyForMoreMediaData = true
    inputMock.appendStub = { buffer in
      let sampleTime = CMSampleBufferGetPresentationTimeStamp(buffer)
      XCTAssert(CMTIME_IS_NUMERIC(sampleTime))
      audioAppended = true
      return true
    }

    camera.startVideoRecording(completion: { error in }, messengerForStreaming: nil)
    camera.pauseVideoRecording()
    camera.resumeVideoRecording()
    camera.captureOutput(
      camera.captureVideoOutput.avOutput, didOutputSampleBuffer: videoSample, from: connectionMock)
    camera.captureOutput(nil, didOutputSampleBuffer: audioSample, from: connectionMock)
    camera.captureOutput(
      camera.captureVideoOutput.avOutput, didOutputSampleBuffer: videoSample, from: connectionMock)
    camera.captureOutput(nil, didOutputSampleBuffer: audioSample, from: connectionMock)

    XCTAssert(videoAppended && audioAppended, "Video or audio was not appended.")
  }

  func testDidOutputSampleBufferMustNotAppendSampleWhenReadyForMoreMediaDataIsFalse() {
    let (camera, _, adaptorMock, inputMock, connectionMock) = createCamera()

    let videoSample = CameraTestUtils.createTestSampleBuffer()

    var sampleAppended = false
    adaptorMock.appendStub = { buffer, time in
      sampleAppended = true
      return true
    }

    camera.startVideoRecording(completion: { error in }, messengerForStreaming: nil)

    inputMock.readyForMoreMediaData = true
    sampleAppended = false
    camera.captureOutput(
      camera.captureVideoOutput.avOutput, didOutputSampleBuffer: videoSample, from: connectionMock)
    XCTAssertTrue(sampleAppended, "Sample was not appended.")

    inputMock.readyForMoreMediaData = false
    sampleAppended = false
    camera.captureOutput(
      camera.captureVideoOutput.avOutput, didOutputSampleBuffer: videoSample, from: connectionMock)
    XCTAssertFalse(sampleAppended, "Sample cannot be appended when readyForMoreMediaData is NO.")
  }

  func testStopVideoRecordingWithCompletionMustCallCompletion() {
    let (camera, writerMock, _, _, _) = createCamera()

    var status = AVAssetWriter.Status.unknown
    writerMock.startWritingStub = {
      status = .writing
      return true
    }
    writerMock.statusStub = {
      return status
    }
    writerMock.finishWritingStub = { handler in
      XCTAssert(
        writerMock.status == .writing,
        "Cannot call finishWritingWithCompletionHandler when status is not AVAssetWriter.Status.writing."
      )
      handler()
    }

    camera.startVideoRecording(completion: { error in }, messengerForStreaming: nil)
    var completionCalled = false
    camera.stopVideoRecording(completion: { path, error in
      completionCalled = true
    })

    XCTAssert(completionCalled, "Completion was not called.")
  }

  func testStartWritingShouldNotBeCalledBetweenSampleCreationAndAppending() {
    let (camera, writerMock, adaptorMock, inputMock, connectionMock) = createCamera()

    let videoSample = CameraTestUtils.createTestSampleBuffer()

    var startWritingCalled = false
    writerMock.startWritingStub = {
      startWritingCalled = true
      return true

    }

    var videoAppended = false
    adaptorMock.appendStub = { buffer, time in
      videoAppended = true
      return true
    }

    inputMock.readyForMoreMediaData = true

    camera.startVideoRecording(completion: { error in }, messengerForStreaming: nil)

    let startWritingCalledBefore = startWritingCalled
    camera.captureOutput(
      camera.captureVideoOutput.avOutput, didOutputSampleBuffer: videoSample, from: connectionMock)
    XCTAssert(
      (startWritingCalledBefore && videoAppended) || (startWritingCalled && !videoAppended),
      "The startWriting was called between sample creation and appending.")

    camera.captureOutput(
      camera.captureVideoOutput.avOutput, didOutputSampleBuffer: videoSample, from: connectionMock)
    XCTAssert(videoAppended, "Video was not appended.")
  }

  func testStartVideoRecordingWithCompletionShouldNotDisableMixWithOthers() {
    let cam = CameraTestUtils.createCameraWithCaptureSessionQueue(DispatchQueue(label: "testing"))

    try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
    cam.startVideoRecording(completion: { error in }, messengerForStreaming: nil)
    XCTAssert(
      AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers),
      "Flag MixWithOthers was removed.")
    XCTAssert(
      AVAudioSession.sharedInstance().category == .playAndRecord,
      "Category should be PlayAndRecord.")
  }
}
