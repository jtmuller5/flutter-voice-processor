//
// Copyright 2020 Picovoice Inc.
//
// You may not use this file except in compliance with the license. A copy of the license is located in the "LICENSE"
// file accompanying this source.
//
// Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
// an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//

import Flutter
import UIKit
import AVFoundation

public class SwiftFlutterVoiceProcessorPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    
    private var bufferEventSink: FlutterEventSink?
    private let audioInputEngine: AudioInputEngine = AudioInputEngine()        
    private var isListening = false
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SwiftFlutterVoiceProcessorPlugin()
        
        let methodChannel = FlutterMethodChannel(name: "flutter_voice_processor_methods", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        
        let eventChannel = FlutterEventChannel(name: "flutter_voice_processor_events", binaryMessenger: registrar.messenger())
        eventChannel.setStreamHandler(instance)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            let args = call.arguments as! [String : Any]
            if let frameLength = args["frameLength"] as? Int,
                let sampleRate = args["sampleRate"] as? Int{
                self.start(frameLength: frameLength, sampleRate: sampleRate, result: result)
            }
            else{
                result(FlutterError(code: "PV_INVALID_ARGUMENT", message: "Invalid argument provided to VoiceProcessor.start", details: nil)) 
            }
        case "stop":
            self.stop()
            result(true)
        case "hasRecordAudioPermission":
            let hasRecordAudioPermission:Bool = self.checkRecordAudioPermission()
            result(hasRecordAudioPermission)
        default: result(FlutterMethodNotImplemented)
            
        }
    }
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.bufferEventSink = events
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {        
        self.bufferEventSink = nil
        return nil
    }
    
    public func start(frameLength: Int, sampleRate: Int, result: @escaping FlutterResult) -> Void {
        
        guard !isListening else {
            NSLog("Audio engine already running.")
            result(true)
            return
        }
        
        audioInputEngine.audioInput = { [weak self] audio in
            
            guard let `self` = self else {
                return
            }
            
            let buffer = UnsafeBufferPointer(start: audio, count: frameLength);            
            self.bufferEventSink?(Array(buffer)) 
        }
        
        let audioSession = AVAudioSession.sharedInstance()        
        
        do{
            try audioSession.setCategory(AVAudioSession.Category.playAndRecord, options: [.mixWithOthers, .defaultToSpeaker])
            try audioSession.setMode(AVAudioSession.Mode.voiceChat)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            try audioInputEngine.start(frameLength:frameLength, sampleRate:sampleRate)
        }
        catch{
            NSLog("Unable to start audio engine: \(error)");
            result(FlutterError(code: "PV_AUDIO_RECORDER_ERROR", message: "Unable to start audio engine: \(error)", details: nil))
            return
        }
        
        isListening = true
        result(true)
    }
    
    private func stop() -> Void{
        guard isListening else {
            return
        }
        
        self.audioInputEngine.stop()

          do {
              try AVAudioSession.sharedInstance().setActive(false)
          }
          catch {
              NSLog("Unable to explicitly deactivate AVAudioSession: \(error)");
          }
        
        isListening = false
    }
    
    private func checkRecordAudioPermission() -> Bool{
        return AVAudioSession.sharedInstance().recordPermission != .denied
    }
    
    
    private class AudioInputEngine {
        private let numBuffers = 3
        private var audioQueue: AudioQueueRef?
        
        var audioInput: ((UnsafePointer<Int16>) -> Void)?
        
        func start(frameLength:Int, sampleRate:Int) throws {
            var format = AudioStreamBasicDescription(
                mSampleRate: Float64(sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 2,
                mFramesPerPacket: 1,
                mBytesPerFrame: 2,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 16,
                mReserved: 0)
            let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            AudioQueueNewInput(&format, createAudioQueueCallback(), userData, nil, nil, 0, &audioQueue)
            
            guard let queue = audioQueue else {
                return
            }
            
            let bufferSize = UInt32(frameLength) * 2
            for _ in 0..<numBuffers {
                var bufferRef: AudioQueueBufferRef? = nil
                AudioQueueAllocateBuffer(queue, bufferSize, &bufferRef)
                if let buffer = bufferRef {
                    AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
                }
            }
            
            AudioQueueStart(queue, nil)
        }
        
        func stop() {
            guard let audioQueue = audioQueue else {
                return
            }
            AudioQueueStop(audioQueue, true)
            AudioQueueDispose(audioQueue, false)
        }
        
        private func createAudioQueueCallback() -> AudioQueueInputCallback {
            return { userData, queue, bufferRef, startTimeRef, numPackets, packetDescriptions in
                
                // `self` is passed in as userData in the audio queue callback.
                guard let userData = userData else {
                    return
                }
                let `self` = Unmanaged<AudioInputEngine>.fromOpaque(userData).takeUnretainedValue()
                
                let pcm = bufferRef.pointee.mAudioData.assumingMemoryBound(to: Int16.self)
                
                if let audioInput = self.audioInput {
                    audioInput(pcm)
                }
                
                AudioQueueEnqueueBuffer(queue, bufferRef, 0, nil)
            }
        }
    }
}
