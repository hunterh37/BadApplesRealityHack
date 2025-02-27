//
//  SharePlayManager.swift
//  BadApples
//
//  Created by Hunter Harris on 1/24/25.
//

import Foundation
import GroupActivities
import Combine
import SwiftUICore
import UIKit
import SharePlayMessages

@available(iOS 17.0, *)

class SharePlayManager: ObservableObject {
    static let shared = SharePlayManager()
    
    @Published var sessionInfo: DemoSessionInfo = .init()
    private var cancellables = Set<AnyCancellable>()
    
    private init() {}
    
    func startSharePlay() {
        Task {
            do {
                let activity = MyGroupActivity()
                let _ = try await activity.activate()
            } catch {
                print("Failed to start SharePlay: \(error.localizedDescription)")
            }
        }
    }
    
    func configureSession(_ session: GroupSession<MyGroupActivity>) {
        self.cleanup()
        
        Task { @MainActor in
            try await Task.sleep(nanoseconds: 1000000000)
            joinSession(session: session)
        }
        
        session.$state.sink { [weak self] state in
            switch state {
            case .invalidated: self?.cleanup()
            default:
                break
            }
        }.store(in: &cancellables)
    }
    
    func joinSession(session: GroupSession<MyGroupActivity>) {
        Task { @MainActor in
            sessionInfo = .init(newSession: session)
            try await Task.sleep(nanoseconds: 1000000000)
            GameStateManager.shared.gameState = .lobbyNotReady
            
            SharePlayManager.subscribeToSessionUpdates()
            SharePlayManager.subscribeToPlayerUpdates()
            
            session.join()
            GameStateManager.shared.gameState = .lobbyNotReady
        }
    }
    
    static func subscribeToSessionUpdates() {
        if let messenger = SharePlayManager.shared.sessionInfo.messenger {
            var task = Task { @MainActor in
                for await (anyMessage, sender) in messenger.messages(of: AnySharePlayMessage.self) {
                    await SharePlayManager.handleMessage(anyMessage, sender: sender.source)
                }
            }
            GameStateManager.shared.tasks.insert(task)
        }
    }
    
    static func subscribeToPlayerUpdates() {
        guard let newSession = SharePlayManager.shared.sessionInfo.session else {
            print("failed to get session"); return }
        
        newSession.$activeParticipants.sink { activeParticipants in
            let localId = newSession.localParticipant.id
            var totalParticipants = activeParticipants.count
            if totalParticipants == 1 {
                totalParticipants += 1
            }
            let isVisionDevice = currentPlatform() == .visionOS
            let localPlayerSeat = isVisionDevice ? 1 : totalParticipants
            Player.local = .init(name: "Player\(localPlayerSeat)",
                                 id: localId,   
                                 score: 0,
                                 isActive: true,
                                 isReady: false,
                                 isVisionDevice: isVisionDevice,
                                 playerSeat: localPlayerSeat)
            GameStateManager.shared.players[localId] = Player.local
            
            for participant in activeParticipants {
                // Calculate seat number based on join order
                let participantIndex = Array(activeParticipants).firstIndex(of: participant) ?? 1
                let seatNumber = participantIndex + 2  // Start at 2 since Vision Pro is 1
                
                let potentialNewPlayer = Player(
                    name: "Player \(seatNumber)",
                    id: participant.id,
                    score: 0,
                    isActive: true,
                    isReady: false,
                    isVisionDevice: false,
                    playerSeat: seatNumber
                )
                
                if !GameStateManager.shared.players.values.contains(where: { $0.id == potentialNewPlayer.id })
                {
                    let task = Task { @MainActor in
                        GameStateManager.shared.players[participant.id] = potentialNewPlayer
                        
                        if GameStateManager.shared.gameState == .inGame {
                            SharePlayManager.sendStartGameMessage()
                        }
                        
                        GameStateManager.shared.sortPlayersByUUID()
                    }
                    GameStateManager.shared.tasks.insert(task)
                }
            }
            
//            if GameStateManager.shared.gameState == .lobbyNotReady && currentPlatform() == .visionOS {
//                var seatId = 1
//                for (_, player) in GameStateManager.shared.players {
//                    if player.isVisionDevice {
//                        var playerCopy = player
//                        playerCopy.playerSeat = 1
//                        SharePlayManager.sendMessage(message: player)
//                        seatId += 1
//                    } else {
//                        var playerCopy2 = player
//                        playerCopy2.playerSeat = seatId
//                        SharePlayManager.sendMessage(message: playerCopy2)
//                        seatId += 1
//                    }
//                }
//            }
        }
        .store(in: &SharePlayManager.shared.cancellables)
    }
    
    static func getColorForSeat(seat: Int) -> UIColor {
        switch seat {
        case 1: return .red
        case 2: return .blue
        case 3: return .purple
        case 4: return .yellow
        default: return .black
        }
    }
    
    /// Handle individual AnySharePlayMessage messages
    @MainActor
    static func handleMessage(_ message: AnySharePlayMessage,
                              sender: Participant,
                              forceHandling: Bool = false) async {
        switch message.base {
        case let message as Player: return
            await PlayerFuncs.handlePlayerMessage(message: message, sender: sender)
        case let message as PlayerReadyMessage:
            return
        case let message as Game_StartMessage:
           await GameStateManager.handleGameStartMsg(message: message, sender: sender)
        case let message as Game_SendHeartMessage:
           await GameStateManager.handleHeartMessage(message: message, sender: sender)
        default: return
        }
    }
    
    static func sendMessage(message: any SharePlayMessage,
                            participants: Set<Participant>? = nil,
                            handleLocally: Bool = false)
    {
        if handleLocally {
            Task {
                if let localParticipant = SharePlayManager.shared.sessionInfo.session?.localParticipant {
                    await SharePlayManager.handleMessage(AnySharePlayMessage(message), sender: localParticipant, forceHandling: handleLocally)
                }
            }
        }
    
        if let session = SharePlayManager.shared.sessionInfo.session,
            let messenger = SharePlayManager.shared.sessionInfo.messenger
        {
            let everyoneElse = session.activeParticipants.subtracting([session.localParticipant])
            let newMessage = AnySharePlayMessage(message)
            messenger.send(newMessage, to: .only(participants ?? everyoneElse)) { error in
                if let error = error { print("Error sending \(message.self) Message: \(error)") }
            }
        }
    }
    
    func cleanup() {
        SharePlayManager.shared.sessionInfo.session?.leave()
        SharePlayManager.shared.sessionInfo.session = nil
        sessionInfo.session = nil
        sessionInfo.messenger = nil
        sessionInfo = .init()
        cancellables.removeAll()
        GameStateManager.shared.gameState = .mainMenu
        GameStateManager.shared.resetGame()
    }
}

extension SharePlayManager {
    static func sendStartGameMessage() {
        let startGameMsg: Game_StartMessage = .init(windowId: "", messageId: "", id: UUID(), gameMode: GameModeManager.shared.gameMode.rawValue)
        sendMessage(message: startGameMsg, handleLocally: false)
    }
}

// Define your custom GroupActivity
@available(iOS 17.0, *)
struct MyGroupActivity: GroupActivity {
    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.title = "My SharePlay Activity"
        metadata.type = .generic
        return metadata
    }
    static var activityIdentifier = "dicyaninlabs.org.shareplay-activity2"
}


class DemoSessionInfo: ObservableObject {
    @Published var session: GroupSession<MyGroupActivity>?
    @Published var messenger: GroupSessionMessenger?
    var reliableMessenger: GroupSessionMessenger?
    var journal: GroupSessionJournal?
    
    init() { }
    init(newSession: GroupSession<MyGroupActivity>) {
        self.session = newSession
        self.messenger = GroupSessionMessenger(session: newSession, deliveryMode: .reliable)
        self.reliableMessenger = GroupSessionMessenger(session: newSession, deliveryMode: .unreliable)
        Task { @MainActor in
            SharePlayManager.shared.sessionInfo = self
        }
    }
}
