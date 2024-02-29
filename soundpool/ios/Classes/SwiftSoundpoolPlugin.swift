import Flutter
import UIKit
import AVFoundation


public class SwiftSoundpoolPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "pl.ukaszapps/soundpool", binaryMessenger: registrar.messenger())
        let instance = SwiftSoundpoolPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    private let counter = Atomic<Int>(0)
    
    private lazy var wrappers = Dictionary<Int,SwiftSoundpoolPlugin.SoundpoolWrapper>()
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initSoundpool":
            // TODO create distinction between different types of audio playback
            let attributes = call.arguments as! NSDictionary
            
            initAudioSession(attributes)
            
            let maxStreams = attributes["maxStreams"] as! Int
            let enableRate = (attributes["ios_enableRate"] as? Bool) ?? true
            let wrapper = SoundpoolWrapper(maxStreams, enableRate)
            
            let index = counter.increment()
            wrappers[index] = wrapper;
            result(index)
        case "dispose":
            let attributes = call.arguments as! NSDictionary
            let index = attributes["poolId"] as! Int
            
            guard let wrapper = wrapperById(id: index) else {
                print("Dispose attempt on not available pool (id: \(index)).")
                result(FlutterError( code: "invalidArgs",
                                     message: "Invalid poolId",
                                     details: "Pool with id \(index) not found" ))
                break
            }
            wrapper.stopAllStreams()
            wrappers.removeValue(forKey: index)
            result(nil)
        default:
            let attributes = call.arguments as! NSDictionary
            let index = attributes["poolId"] as! Int
            
            guard let wrapper = wrapperById(id: index) else {
                print("Action '\(call.method)' attempt on not available pool (id: \(index)).")
                result(FlutterError( code: "invalidArgs",
                                     message: "Invalid poolId",
                                     details: "Pool with id \(index) not found" ))
                break
            }
            wrapper.handle(call, result: result)
        }
    }
    
    private func initAudioSession(_ attributes: NSDictionary) {
        if #available(iOS 10.0, *) {
            // guard against audio_session plugin and avoid doing redundant session management
            if (NSClassFromString("AudioSessionPlugin") != nil) {
                print("AudioSession should be managed by 'audio_session' plugin")
                return
            }
            
            
            guard let categoryAttr = attributes["ios_avSessionCategory"] as? String else {
                return
            }
            let modeAttr = attributes["ios_avSessionMode"] as! String
            
            let category: AVAudioSession.Category
            switch categoryAttr {
            case "ambient":
                category = .ambient
            case "playback":
                category = .playback
            case "playAndRecord":
                category = .playAndRecord
            case "multiRoute":
                category = .multiRoute
            default:
                category = .soloAmbient
                
            }
            let mode: AVAudioSession.Mode
            switch modeAttr {
            case "moviePlayback":
                mode = .moviePlayback
            case "videoRecording":
                mode = .videoRecording
            case "voiceChat":
                mode = .voiceChat
            case "gameChat":
                mode = .gameChat
            case "videoChat":
                mode = .videoChat
            case "spokenAudio":
                mode = .spokenAudio
            case "measurement":
                mode = .measurement
            default:
                mode = .default
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(category, mode: mode)
                print("Audio session updated: category = '\(category)', mode = '\(mode)'.")
            } catch (let e) {
                //do nothing
                print("Error while trying to set audio category: '\(e)'")
            }
        }
    }
    
    private func wrapperById(id: Int) -> SwiftSoundpoolPlugin.SoundpoolWrapper? {
        if (id < 0){
            return nil
        }
        let wrapper = wrappers[id]
        return wrapper
    }
    
class SoundpoolWrapper : NSObject {
    private var maxStreams: Int
    private var enableRate: Bool
    private var streamIdProvider = Atomic<Int>(0)
    private lazy var soundpool = [AVAudioPlayer?]()
    private lazy var streamsCount: Dictionary<Int, Int> = [Int: Int]()
    private lazy var nowPlaying: Dictionary<Int, NowPlaying> = [Int: NowPlaying]()
    
    init(_ maxStreams: Int, _ enableRate: Bool){
        self.maxStreams = maxStreams
        self.enableRate = enableRate
        super.init()
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let attributes = call.arguments as! NSDictionary
        switch call.method {
        case "load":
            let rawSound = attributes["rawSound"] as! FlutterStandardTypedData
            do {
                let audioPlayer = try AVAudioPlayer(data: rawSound.data)
                if (enableRate){
                    audioPlayer.enableRate = true
                }
                audioPlayer.prepareToPlay()
                let index = soundpool.count
                soundpool.append(audioPlayer)
                result(index)
            } catch {
                result(-1)
            }
        case "play":
            let soundId = attributes["soundId"] as! Int
            let times = attributes["repeat"] as? Int
            let rate = (attributes["rate"] as? Double) ?? 1.0
            if (soundId < 0){
                result(0)
                break
            }
            
            guard let audioPlayer = playerBySoundId(soundId: soundId) else {
                result(0)
                break
            }
            
            do {
                let currentCount = streamsCount[soundId] ?? 0
                
                if (currentCount >= maxStreams){
                    result(0)
                    break
                }
                
                let nowPlayingData: NowPlaying
                let streamId: Int = streamIdProvider.increment()
                
                let delegate = SoundpoolDelegate(pool: self, soundId: soundId, streamId: streamId)
                audioPlayer.delegate = delegate
                nowPlayingData =  NowPlaying(player: audioPlayer, delegate: delegate)
                
                audioPlayer.numberOfLoops = times ?? 0
                if (enableRate){
                    audioPlayer.enableRate = true
                    audioPlayer.rate = Float(rate)
                }
                
                if (audioPlayer.play()) {
                    streamsCount[soundId] = currentCount + 1
                    nowPlaying[streamId] = nowPlayingData
                    result(streamId)
                } else {
                    result(0) // failed to play sound
                }
            } catch {
                result(0)
            }
        case "pause":
            let streamId = attributes["streamId"] as! Int
            if let playingData = playerByStreamId(streamId: streamId) {
                playingData.player.pause()
                result(streamId)
            } else {
                result (-1)
            }
        case "resume":
            let streamId = attributes["streamId"] as! Int
            if let playingData = playerByStreamId(streamId: streamId) {
                playingData.player.play()
                result(streamId)
            } else {
                result (-1)
            }
        case "stop":
            let streamId = attributes["streamId"] as! Int
            if let nowPlaying = playerByStreamId(streamId: streamId) {
                let audioPlayer = nowPlaying.player
                audioPlayer.stop()
                result(streamId)
                // removing player
                self.nowPlaying.removeValue(forKey: streamId)
                nowPlaying.delegate.decreaseCounter()
                audioPlayer.delegate = nil
            } else {
                result(-1)
            }
        case "release":
            stopAllStreams()
            soundpool.removeAll()
            result(nil)
        default:
            result("notImplemented")
        }
    }
    
    func stopAllStreams() {
        for audioPlayer in soundpool {
            audioPlayer?.stop()
        }
    }
    
    private func playerByStreamId(streamId: Int) -> NowPlaying? {
        let audioPlayer = nowPlaying[streamId]
        return audioPlayer
    }
    
    private func playerBySoundId(soundId: Int) -> AVAudioPlayer? {
        if (soundId >= soundpool.count || soundId < 0){
            return nil
        }
        if let audioPlayer = soundpool[soundId] {
            if (audioPlayer.isPlaying) {
                audioPlayer.stop()
                audioPlayer.currentTime = 0
            }
            return audioPlayer
        } else {
            return nil
        }
    }
    
    private class SoundpoolDelegate: NSObject, AVAudioPlayerDelegate {
        private var soundId: Int
        private var streamId: Int
        private var pool: SoundpoolWrapper
        init(pool: SoundpoolWrapper, soundId: Int, streamId: Int) {
            self.soundId = soundId
            self.pool = pool
            self.streamId = streamId
        }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            decreaseCounter()
        }
        func decreaseCounter(){
            pool.streamsCount[soundId] = (pool.streamsCount[soundId] ?? 1) - 1
            pool.nowPlaying.removeValue(forKey: streamId)
        }
    }
    
    private struct NowPlaying {
        let player: AVAudioPlayer
        let delegate: SoundpoolDelegate
    }
  }
}
