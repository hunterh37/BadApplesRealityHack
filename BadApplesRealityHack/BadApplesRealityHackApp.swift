//
//  BadApplesRealityHackApp.swift
//  BadApplesRealityHack
//
//  Created by Hunter Harris on 1/24/25.
//

import SwiftUI

@main
struct BadApplesRealityHackApp: App {

    @State private var appModel = AppModel()
    @State private var currentStyle: ImmersionStyle = .progressive
    
    init() {
        ScalingSystem.registerSystem()
        ScalingComponent.registerComponent()
        
        HeartMovementSystem.registerSystem()
        HeartMovementComponent.registerComponent()
    }

    var body: some Scene {
        WindowGroup {
            GameContainerViewVision()
                .environment(appModel)
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView(immersionStyle: currentStyle)
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
