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
    private var referenceP = simd_float3(0, 0, 0)
    
    @Published var neckOffsetY: Float = 0.15
    @Published var neckOffsetZ: Float = -0.08
    
    @Published var ipd: Float = 0.063 {
        didSet { updateIPD() }
    }
    @Published var fieldOfView: CGFloat = 32.8 {
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
        
        lv.scene.anchors.removeAll()
        rv.scene.anchors.removeAll()
        
        func configure(_ view: ARView, _ head: Entity, _ cam: PerspectiveCamera) {
            let anchor = AnchorEntity(world: .zero)
            view.environment.background = .color(.black) // または .darkGray など
            
            view.environment.lighting.intensityExponent = 1.0
            
            let sun = DirectionalLight()
            sun.light.intensity = 15000
            sun.light.color = .white
            sun.shadow = DirectionalLightComponent.Shadow()
            
            let sunEntity = Entity()
            sunEntity.orientation = simd_quatf(angle: .pi * 0.25, axis: [1, 0, 0]) * simd_quatf(angle: .pi * -0.25, axis: [0, 1, 0])
            sunEntity.addChild(sun)
            anchor.addChild(sunEntity)

            let mesh = MeshResource.generateSphere(radius: 0.1)
            var pbr = PhysicallyBasedMaterial()
            
            // 色の指定をシンプルに修正
            pbr.baseColor = .init(tint: .blue)
            pbr.metallic = 0.9
            pbr.roughness = 0.1
            pbr.clearcoat = 0.6
            pbr.clearcoatRoughness = 0.05
            
            let sphere = ModelEntity(mesh: mesh, materials: [pbr])
            sphere.position = [0, 0, -0.5] // カメラの前方50cm
            anchor.addChild(sphere)
            
            // 3. カメラの組み立て
            head.children.removeAll() // 二重追加防止
            head.addChild(cam)
            anchor.addChild(head)
            
            view.scene.addAnchor(anchor)
            cam.camera.fieldOfViewInDegrees = Float(fieldOfView)
        }
        
        configure(lv, leftHead, leftCamera)
        configure(rv, rightHead, rightCamera)
        
        updateIPD()
        
        subscription?.cancel()
        subscription = lv.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.onUpdate()
        }
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
            referenceP = p
        }
        
        let targetQ = referenceQ * q
        let rawRelativeP = p - referenceP
        let rotatedRelativeP = referenceQ.act(rawRelativeP)
        let targetP = rotatedRelativeP * positionScale
        
        let neckOffset = simd_float3(0, neckOffsetY, neckOffsetZ)
        let eyeMovement = targetQ.act(neckOffset) - neckOffset
        let finalP = targetP + eyeMovement
        
        leftHead.orientation = targetQ
        rightHead.orientation = targetQ
        
        leftHead.position = finalP
        rightHead.position = finalP
        
        DispatchQueue.main.async {
            self.debugPosition = targetP
        }
    }
}

