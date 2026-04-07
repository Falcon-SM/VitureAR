//
//  Spatial.swift
//  VitureAR
//
//  Created by Shun Matsumoto on 2026/04/07.
//

import Foundation
import ARKit
import SwiftUI
import RealityKit
import simd
import Combine
internal import AVFoundation

class SpacialCoordinator: ObservableObject {
    // Prevent Memory Leak
    weak var leftView: ARView?
    weak var rightView: ARView?
    
    // AR Object
    let leftHead = Entity()
    let rightHead = Entity()
    
    private let lock = NSLock()
    let leftCamera = PerspectiveCamera(), rightCamera = PerspectiveCamera()
    private var quaternion = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var position = simd_float3(0, 0, 0)
    private var reset =  true
    private var subscription: Cancellable?
    private var referenceQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    
    @Published var ipd: Float = 0.063 {
        didSet { updateIPD() }
    }
    @Published var fieldOfView: CGFloat = 46.0 {
            didSet {
                leftCamera.camera.fieldOfViewInDegrees = Float(fieldOfView)
                rightCamera.camera.fieldOfViewInDegrees = Float(fieldOfView)
            }
    }
    @Published var positionScale: Float = 1.0
    @Published var debugPosition: simd_float3 = .zero
    
    func updatePose(p: simd_float3, q: simd_quatf){
        lock.lock()
        position = p
        quaternion = q
        lock.unlock()
    }
    
    func recenter() {
        lock.lock()
        reset = true
        lock.unlock()
    }
    
    func setup() {
        guard let lv = leftView, let rv = rightView else { return }
        
        func configure(_ view: ARView, _ head: Entity, _ cam: PerspectiveCamera) {
            let anchor = AnchorEntity(world: .zero) // Center
            head.addChild(cam)
            anchor.addChild(head)
            view.scene.addAnchor(anchor)
            cam.camera.fieldOfViewInDegrees = 46
        }
        
        configure(lv, leftHead, leftCamera)
        configure(rv, rightHead, rightCamera)
        
        updateIPD()
        
        subscription = lv.scene.subscribe(to: SceneEvents.Update.self) { [weak  self] _ in self?.onUpdate() }
    }
    
    private func updateIPD() {
        let halfIPD = ipd / 2.0
        leftCamera.position = [-halfIPD, 0, 0]
        rightCamera.position = [halfIPD, 0, 0]
    }
    
    private func onUpdate() {
        var p: simd_float3; var q: simd_quatf; var willReset: Bool
        
        lock.lock()
        p = position; q = quaternion; willReset = reset
        if reset { reset = false }
        lock.unlock()
        
        if willReset {
            let forward = q.act(simd_float3(0, 0, -1))
            let yaw = atan2(forward.x, -forward.z)
            referenceQ = simd_quatf(angle: yaw, axis: [0, 1, 0]).inverse
        }
        
        let targetQ = referenceQ * q
        
        let smoothQ = simd_slerp(leftHead.orientation, targetQ, 0.4)
        leftHead.orientation = smoothQ
        rightHead.orientation = smoothQ
        
        let smoothP = leftHead.position + (p - leftHead.position) * 0.4
        leftHead.position = smoothP
        rightHead.position = smoothP
    }
}
