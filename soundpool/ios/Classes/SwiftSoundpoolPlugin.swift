import Flutter
import UIKit
import AVFoundation


public class SwiftSoundpoolPlugin: NSObject, FlutterPlugin {
    private var maxStreams: Int
    private var enableRate: Bool
    private var streamIdProvider = Atomic<Int>(0)
    private lazy var soundpool = [AVAudioPlayer]()
    private lazy var streamsCount: Dictionary<Int, Int> = [Int: Int]()
    private lazy var nowPlaying: Dictionary<Int, NowPlaying> = [Int: NowPlaying]()
    
    init(_ maxStreams: Int, _ enableRate: Bool){
        self.maxStreams = maxStreams
        self.enableRate = enableRate
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
        case "loadUri":
            let soundUri = attributes["uri"] as! String
            let url = URL(string: soundUri)
            if (url != nil){
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let cachedSound = try Data(contentsOf: url!, options: NSData.ReadingOptions.mappedIfSafe)
                        DispatchQueue.main.async {
                            var value:Int = -1
                            do {
                                let audioPlayer = try AVAudioPlayer(data: cachedSound)
                                if (self.enableRate){
                                    audioPlayer.enableRate = true
                                }
                                audioPlayer.prepareToPlay()
                                let index = self.soundpool.count
                                self.soundpool.append(audioPlayer)
                                value = index
                            } catch {
                                print("Unexpected error while preparing player: \(error).")
                            }
                            result(value)
                        }
                    } catch {
                        print("Unexpected error while downloading file: \(error).")
                        DispatchQueue.main.async {
                            result(-1)
                        }
                    }
                }
            } else {
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
            
            guard var audioPlayer = playerBySoundId(soundId: soundId) else {
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
                nowPlayingData = NowPlaying(player: audioPlayer, delegate: delegate)
                
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
        case "setVolume":
            let streamId = attributes["streamId"] as? Int
            let soundId = attributes["soundId"] as? Int
            let volume = attributes["volume"] as? Double
            let volumeLeft = attributes["volumeLeft"] as? Double
            let volumeRight = attributes["volumeRight"] as? Double
            
            var audioPlayer: AVAudioPlayer? = nil;
            if (streamId != nil){
                audioPlayer = playerByStreamId(streamId: streamId!)?.player
            } else if (soundId != nil){
                audioPlayer = playerBySoundId(soundId: soundId!)
            }
            
            if let volumeLeft = volumeLeft, let volumeRight = volumeRight {
                // Normalize volumeLeft and volumeRight to ensure they sum up to 1.0
                let totalVolume = volumeLeft + volumeRight
                let normalizedVolumeLeft = volumeLeft / totalVolume
                let normalizedVolumeRight = volumeRight / totalVolume
                
                audioPlayer?.pan = Float(normalizedVolumeRight - normalizedVolumeLeft) // Set panning
            }
            
            if let volume = volume {
                audioPlayer?.volume = Float(volume) // Set specified volume
            } else {
                audioPlayer?.volume = Float((volumeLeft ?? 0.5) + (volumeRight ?? 0.5)) // Set average volume if volume is not provided
            }
            
            result(nil)
            
        case "setRate":
            if (enableRate){
                let streamId = attributes["streamId"] as! Int
                let rate = (attributes["rate"] as? Double) ?? 1.0
                let audioPlayer: AVAudioPlayer? = playerByStreamId(streamId: streamId)?.player
                audioPlayer?.rate = Float(rate)
            }
            result(nil)
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
            audioPlayer.stop()
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
        let audioPlayer = soundpool[soundId]
        return audioPlayer
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
