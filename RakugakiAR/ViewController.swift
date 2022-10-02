//
//  ViewController.swift
//  RakugakiAR
//
//  Created by Tatsuya Ogawa on 2022/10/02.
//

import ARKit
import Vision
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

class ViewController: UIViewController, ARSessionDelegate, ARSCNViewDelegate {

    @IBOutlet weak var scnView: ARSCNView!
    // 輪郭描画用
    private var contourPathLayer: CAShapeLayer?
    // キャプチャ画像上の輪郭検出範囲
    private let detectSize: CGFloat = 320.0
    // ３次元化ボタンが押下状態
    private var isButtonPressed = false
    // 床の厚さ(m)
    private let floorThickness: CGFloat = 1.0
    // 床のローカル座標。床の厚さ分、Y座標を下げる
    private lazy var floorLocalPosition = SCNVector3(0.0, -self.floorThickness/2, 0.0)
    // SCNShapeの仮の拡大率。SCNShapeに小さいジオメトリ を与えるとジオメトリが崩れるので拡大する
    private let tempGeometryScale: CGFloat = 10.0
    // 検出領域の四隅のシーン内の位置を示すマーカーノード
    private var cornerMarker1: SCNNode!
    private var cornerMarker2: SCNNode!
    private var cornerMarker3: SCNNode!
    private var cornerMarker4: SCNNode!
    // 輪郭検出範囲
    private var leftTop: SCNVector3?
    private var rightTop: SCNVector3?
    private var leftBottom: SCNVector3?
    private var rightBottom: SCNVector3?
    // テクスチャを貼るノードのポリンゴンのインデックス
    private let indices: [Int32] = [
        0, 2, 1,    // 左上、左下、右上の三角形
        1, 2, 3,    // 右上、左下、右下の三角形
    ]
    // テクスチャ座標
    private let texcoords: [CGPoint] = [
        CGPoint(x: 0.0, y: 0.0),    // 左上
        CGPoint(x: 1.0, y: 0.0),    // 右上
        CGPoint(x: 0.0, y: 1.0),    // 左下
        CGPoint(x: 1.0, y: 1.0),    // 右下
    ]

    override func viewDidLoad() {
        super.viewDidLoad()

        // シーンの設定
        self.setupScene()
        // AR Session 開始
        self.scnView.delegate = self
        self.scnView.session.delegate = self
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        self.scnView.session.run(configuration, options: [.removeExistingAnchors, .resetTracking])
    }

    // アンカーが追加された
    func renderer(_: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard anchor is ARPlaneAnchor else { return }

        // 床ノードを追加
        let floorNode = makeFloorNode()
        DispatchQueue.main.async {
            node.addChildNode(floorNode)
        }
    }

    // アンカーが更新された
    func renderer(_: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard anchor is ARPlaneAnchor else { return }

        if let childNode = node.childNodes.first {
            DispatchQueue.main.async {
                // 床ノードの位置を再設定
                childNode.position = self.floorLocalPosition
            }
        }
    }

    // ARフレームが更新された
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // キャプチャ画像をスクリーンで見える範囲に切り抜く
        let screenImage = cropScreenImageFromCapturedImage(frame: frame)
        // 一番外側の輪郭を取得
        guard let contour = getFirstOutsideContour(screenImage: screenImage) else { return }
        // UIKitの座標系のCGPathを取得
        guard let path = getCGPathInUIKitSpace(contour: contour) else { return }

        DispatchQueue.main.async {
            // 輪郭(2D)を描画
            self.drawContourPath(path)
            // 輪郭(3D)を描画
            let croppedImage = screenImage.cropped(to: CGRect(x: screenImage.extent.width/2 - self.detectSize/2,
                                                              y: screenImage.extent.height/2 - self.detectSize/2,
                                                              width: self.detectSize,
                                                              height: self.detectSize))
            if  self.isButtonPressed {
                self.isButtonPressed = false
                self.drawContour3DModel(normalizedPath: contour.normalizedPath, captureImage: croppedImage)
            }
        }
    }

    private func setupScene() {
        // ディレクショナルライト追加
        let directionalLightNode = SCNNode()
        directionalLightNode.light = SCNLight()
        directionalLightNode.light?.type = .directional
        directionalLightNode.light?.castsShadow = true  // 影が出るライトにする
        directionalLightNode.light?.shadowMapSize = CGSize(width: 2048, height: 2048)   // シャドーマップを大きくしてジャギーが目立たないようにする
        directionalLightNode.light?.shadowSampleCount = 2   // 影の境界を若干柔らかくする
        directionalLightNode.light?.shadowColor = UIColor.lightGray.withAlphaComponent(0.8) // 影の色は明るめ
        directionalLightNode.position = SCNVector3(x: 0, y: 3, z: 0)
        directionalLightNode.eulerAngles = SCNVector3(x: -Float.pi/3, y: 0, z: -Float.pi/3)
        self.scnView.scene.rootNode.addChildNode(directionalLightNode)
        // 暗いので環境光を追加
        let ambientLightNode = SCNNode()
        ambientLightNode.light = SCNLight()
        ambientLightNode.light?.type = .ambient
        directionalLightNode.position = SCNVector3(x: 0, y: 0, z: 0)
        self.scnView.scene.rootNode.addChildNode(ambientLightNode)
        // 検出領域の四隅のシーン内のマーカーノード
        self.cornerMarker1 = makeMarkerNode()
        self.cornerMarker1.isHidden = true
        self.scnView.scene.rootNode.addChildNode(self.cornerMarker1)
        self.cornerMarker2 = makeMarkerNode()
        self.cornerMarker2.isHidden = true
        self.scnView.scene.rootNode.addChildNode(self.cornerMarker2)
        self.cornerMarker3 = makeMarkerNode()
        self.cornerMarker3.isHidden = true
        self.scnView.scene.rootNode.addChildNode(self.cornerMarker3)
        self.cornerMarker4 = makeMarkerNode()
        self.cornerMarker4.isHidden = true
        self.scnView.scene.rootNode.addChildNode(self.cornerMarker4)
    }

    // ジオメトリ化ボタンが押された
    @IBAction func pressButton(_ sender: Any) {
        isButtonPressed = true
    }
}

// MARK: - 輪郭検出関連

extension ViewController {

    private func getFirstOutsideContour(screenImage: CIImage) -> VNContour? {
        // 輪郭検出しやすいように画像処理を行う
        guard let preprocessedImage = preprocessForDetectContour(screenImage: screenImage) else { return nil }
        // 輪郭検出
        let handler = VNImageRequestHandler(ciImage: preprocessedImage)
        let contourRequest = VNDetectContoursRequest.init()
        contourRequest.maximumImageDimension = Int(self.detectSize) // 検出画像サイズはクリップした画像と同じにする。デフォルトは512。
        contourRequest.detectsDarkOnLight = true                    // 明るい背景で暗いオブジェクトを検出
        try? handler.perform([contourRequest])
        // 検出結果取得
        guard let observation = contourRequest.results?.first as? VNContoursObservation else { return nil }
        // トップレベルの輪郭のうち、輪郭の座標数が一番多いパスを見つける
        let outSideContour = observation.topLevelContours.max(by: { $0.normalizedPoints.count < $1.normalizedPoints.count })
        if let contour = outSideContour {
            return contour
        } else {
            return nil
        }
    }

    private func cropScreenImageFromCapturedImage(frame: ARFrame) -> CIImage {

        let imageBuffer = frame.capturedImage
        // カメラキャプチャ画像をスクリーンサイズに変換
        // 参考 : https://stackoverflow.com/questions/58809070/transforming-arframecapturedimage-to-view-size
        let imageSize = CGSize(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))
        let viewPortSize = self.scnView.bounds.size
        let interfaceOrientation  = self.scnView.window!.windowScene!.interfaceOrientation
        let image = CIImage(cvImageBuffer: imageBuffer)
        // 1) キャプチャ画像を 0.0〜1.0 の座標に変換
        let normalizeTransform = CGAffineTransform(scaleX: 1.0/imageSize.width, y: 1.0/imageSize.height)
        // 2) 「Flip the Y axis (for some mysterious reason this is only necessary in portrait mode)」とのことでポートレートの場合に座標変換。
        //     Y軸だけでなくX軸も反転が必要。
        var flipTransform = CGAffineTransform.identity
        if interfaceOrientation.isPortrait {
            // X軸Y軸共に反転
            flipTransform = CGAffineTransform(scaleX: -1, y: -1)
            // X軸Y軸共にマイナス側に移動してしまうのでプラス側に移動
            flipTransform = flipTransform.concatenating(CGAffineTransform(translationX: 1, y: 1))
        }
        // 3) キャプチャ画像上でのスクリーンの向き・位置に移動
        // 参考 : https://developer.apple.com/documentation/arkit/arframe/2923543-displaytransform
        let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewPortSize)
        // 4) 0.0〜1.0 の座標系からスクリーンの座標系に変換
        let toViewPortTransform = CGAffineTransform(scaleX: viewPortSize.width, y: viewPortSize.height)
        // 5) 1〜4までの変換を行い、変換後の画像をスクリーンサイズでクリップ
        let transformedImage = image.transformed(by: normalizeTransform.concatenating(flipTransform).concatenating(displayTransform).concatenating(toViewPortTransform)).cropped(to: self.scnView.bounds)
        return transformedImage
    }

    private func preprocessForDetectContour(screenImage: CIImage) -> CIImage? {
        // 画像の暗い部分を広げて細い線を太くする。
        // WWDC2020(https://developer.apple.com/videos/play/wwdc2020/10673/)
        // 04:06あたりで紹介されているCIMorphologyMinimumを利用。
        let blurFilter = CIFilter.morphologyMinimum()
        blurFilter.inputImage = screenImage
        blurFilter.radius = 5
        guard let blurImage = blurFilter.outputImage else { return nil }
        // ペンの線を強調。RGB各々について閾値より明るい色は 1.0 にする。
        let thresholdFilter = CIFilter.colorThreshold()
        thresholdFilter.inputImage = blurImage
        thresholdFilter.threshold = 0.1
        guard let thresholdImage = thresholdFilter.outputImage else { return nil }
        // 検出範囲を画面の中心部分に限定する
        let screenImageSize = screenImage.extent    // CIMorphologyMinimumフィルタにより画像サイズと位置が変わってしまうので、オリジナル画像のサイズ・位置を基準にする
        let croppedImage = thresholdImage.cropped(to: CGRect(x: screenImageSize.width/2 - detectSize/2,
                                                             y: screenImageSize.height/2 - detectSize/2,
                                                             width: detectSize,
                                                             height: detectSize))
        return croppedImage
    }
}
// MARK: - パス描画（2D）

extension ViewController {

    private func getCGPathInUIKitSpace(contour: VNContour) -> CGPath? {
        // UIKitで使うため、クリップしたときのサイズに拡大し、上下の座標を反転後、左上が (0,0)になるようにする
        let path = contour.normalizedPath
        var transform = CGAffineTransform(scaleX: detectSize, y: -detectSize)
        transform = transform.concatenating(CGAffineTransform(translationX: 0, y: detectSize))
        let transPath = path.copy(using: &transform)
        return transPath
    }

    private func drawContourPath(_ path: CGPath) {
        // 表示中のパスは消す
        if let layer = self.contourPathLayer {
            layer.removeFromSuperlayer()
            self.contourPathLayer = nil
        }
        // 輪郭を描画
        let pathLayer = CAShapeLayer()
        var frame = self.view.bounds
        frame.origin.x = frame.width/2 - detectSize/2
        frame.origin.y = frame.height/2 - detectSize/2
        frame.size.width = detectSize
        frame.size.height = detectSize
        pathLayer.frame = frame
        pathLayer.path = path
        pathLayer.strokeColor = UIColor.blue.cgColor
        pathLayer.lineWidth = 10
        pathLayer.fillColor = UIColor.clear.cgColor
        self.view.layer.addSublayer(pathLayer)
        self.contourPathLayer = pathLayer
    }
}
// MARK: - パス描画（3D）

extension ViewController {

    private func drawContour3DModel(normalizedPath: CGPath, captureImage: CIImage) {
        // ベジェパスをもとにノードを生成
        guard let node = makeNode(from: normalizedPath, captureImage: captureImage) else { return }

        // 画面中央上の20cm上から落とす
        let screenCenter = CGPoint(x: self.view.bounds.width/2, y: self.view.bounds.height/2 - 150)
        guard var position = self.getWorldPosition(from: screenCenter) else { return }
        position.y += 0.2
        node.worldPosition = position
        self.scnView.scene.rootNode.addChildNode(node)
    }

    // レイキャストでワールド座標を取得
    private func getWorldPosition(from: CGPoint) -> SCNVector3? {

        guard let query = self.scnView.raycastQuery(from: from, allowing: .existingPlaneGeometry, alignment: .horizontal),
              let result = self.scnView.session.raycast(query).first else {
            return nil
        }
        let p = result.worldTransform.columns.3
        return SCNVector3(p.x, p.y, p.z)
    }

    private func makeFloorNode() -> SCNNode {
        // 落ちてくるノードを受け止めるためアンカーに大きめなSCNBoxを設定する。
        let geometry = SCNBox(width: 3.0, height: 3.0, length: self.floorThickness, chamferRadius: 0.0)
        let material = SCNMaterial()
        material.lightingModel = .shadowOnly    // 平面の色は影だけになるように指定
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.position = self.floorLocalPosition
        node.castsShadow = false                // これがないとplaneNodeがチラつくことがある
        node.transform = SCNMatrix4MakeRotation(-Float.pi / 2, 1, 0, 0)
        node.physicsBody = SCNPhysicsBody.static()
        node.physicsBody?.friction = 1.0        // この辺りのプロパティはモデルの物理運動を抑止するためのもの
        node.physicsBody?.restitution = 0.0
        node.physicsBody?.rollingFriction = 1.0
        node.physicsBody?.angularDamping = 1.0
        node.physicsBody?.linearRestingThreshold = 1.0
        node.physicsBody?.angularRestingThreshold = 1.0

        return node
    }

    private func makeMarkerNode() -> SCNNode {

        let sphere = SCNSphere(radius: 0.001)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.red
        sphere.materials = [material]
        return SCNNode(geometry: sphere)
    }

    private func convertPath(from normalizedPath: CGPath) -> UIBezierPath? {
        // 検出領域の四隅のワールド座標を取得
        let origin = CGPoint(x: self.view.bounds.width/2 - self.detectSize/2,
                             y: self.view.bounds.height/2 - self.detectSize/2)
        guard let leftTopWorldPosition = self.getWorldPosition(from: origin),
              let rightTopWorldPosition = self.getWorldPosition(from: CGPoint(x: origin.x + self.detectSize,
                                                                              y: origin.y)),
              let leftBottomWorldPosition = self.getWorldPosition(from: CGPoint(x: origin.x,
                                                                                y: origin.y + self.detectSize)),
              let rightBottomWorldPosition = self.getWorldPosition(from: CGPoint(x: origin.x + self.detectSize,
                                                                                 y: origin.y + self.detectSize)) else {
            print("検出領域の四隅のワールド座標が取れない。iPhoneを前後左右に動かしてください。")
            return nil
        }
        // 検出した座標にワールド座標位置確認用の赤い球を配置
        self.cornerMarker1.worldPosition = leftTopWorldPosition
        self.cornerMarker1.isHidden = false
        self.cornerMarker2.worldPosition = rightTopWorldPosition
        self.cornerMarker2.isHidden = false
        self.cornerMarker3.worldPosition = leftBottomWorldPosition
        self.cornerMarker3.isHidden = false
        self.cornerMarker4.worldPosition = rightBottomWorldPosition
        self.cornerMarker4.isHidden = false
        // 四隅の座標をワールド座標の中心を基準にした座標に変換
        let worldCenter = (leftTopWorldPosition + rightTopWorldPosition + leftBottomWorldPosition + rightBottomWorldPosition) / 4
        self.leftTop = leftTopWorldPosition - worldCenter
        self.rightTop = rightTopWorldPosition - worldCenter
        self.leftBottom = leftBottomWorldPosition - worldCenter
        self.rightBottom = rightBottomWorldPosition - worldCenter
        // ２次元のCGPathを３次元の座標系に変換
        let geometryPath = UIBezierPath()
        let path = Path(normalizedPath)
        var elementCount = 0
        path.forEach { element in
            switch element {
            case .move(to: let to):
                geometryPath.move(to: convertPathPoint(to))
            case .line(to: let to):
                geometryPath.addLine(to: convertPathPoint(to))
            case .quadCurve(to: let to, control: _):
                geometryPath.addLine(to: convertPathPoint(to))
            case .curve(to: let to, control1: _, control2: _):
                geometryPath.addLine(to: convertPathPoint(to))
            case .closeSubpath:
                geometryPath.close()
                break
            }
            elementCount += 1
        }
        print("path element count[\(elementCount)]")
        return geometryPath
    }

    private func convertPathPoint(_ from: CGPoint) -> CGPoint {

        guard let leftTop = self.leftTop,
              let rightTop = self.rightTop,
              let leftBottom = self.leftBottom,
              let rightBottom = self.rightBottom else {
            return CGPoint.zero
        }
        //　パスの各座標について三角形の重心座標系でワールド座標を導出
        var point = CGPoint.zero
        let pl: CGFloat = 1.0     // CGPathの一辺の長さ。VNContourの返す輪郭は(0,0)〜(1,1)の範囲
        if from.y > from.x {
            // 四角形の上側の三角形
            let t: CGFloat = pl * pl / 2    // 四角形の上側の三角形の面積
            let t2 = pl * (pl - from.y) / 2   // t2の面積
            let t3 = pl * from.x / 2          // t3の面積
            let t1 = t - t2 - t3            // t1の面積

            let ltRatio = t1 / t    // 左上座標の割合
            let rtRatio = t3 / t    // 右上座標の割合
            let lbRatio = t2 / t    // 左下座標の割合

            // 各頂点の重みに応じてワールド座標を算出
            let p = leftTop * ltRatio + rightTop * rtRatio + leftBottom * lbRatio
            point.x = p.x.cg
            point.y = p.z.cg * -1
        } else {
            // 四角形の下側の三角形
            let t: CGFloat = pl * pl / 2    // 四角形の下側の三角形の面積
            let t5 = pl * from.y / 2          // t5の面積
            let t6 = pl * (pl - from.x) / 2   // t6の面積
            let t4 = t - t5 - t6            // t4の面積

            let rtRatio = t5 / t    // 右上座標の割合
            let lbRatio = t6 / t    // 左下座標の割合
            let rbRatio = t4 / t    // 右下座標の割合

            // 各頂点の重みに応じてワールド座標を算出
            let p = rightTop * rtRatio + leftBottom * lbRatio + rightBottom * rbRatio
            point.x = p.x.cg
            point.y = p.z.cg * -1
        }
        // 後でSCNShapeに与える座標となるが、SCNShapeに小さい座標を与えると正しく表示されないのでいったん、拡大しておく。
        return point * self.tempGeometryScale
    }

    private func makeNode(from normalizedPath: CGPath, captureImage: CIImage) -> SCNNode? {
        // 輪郭(CGPath)をワールド座標のUIBezierPathに変換
        guard let geometryPath = convertPath(from: normalizedPath) else { return nil }

        // パスの厚みを持つノードと表面のテクスチャが貼られた平面ノードの親ノードを作成
        let node = SCNNode()
        node.position = SCNVector3(x: 0.0, y: 0.0, z: 0.0)

        // ベジェ曲線から3Dモデルを作成
        let pathShapeNode = makePathShapeNode(geometryPath: geometryPath)
        pathShapeNode.position = SCNVector3(x: 0.0, y: 0.0, z: 0.0)
        node.addChildNode(pathShapeNode)

        // 3Dモデルの表面ノードを作成
        guard let shapeFaceNode = makeShapeFaceNode(from: normalizedPath, captureImage: captureImage) else { return nil }
        shapeFaceNode.eulerAngles = SCNVector3(x: Float.pi/2, y: 0, z: 0)
        shapeFaceNode.position = SCNVector3(0, 0.0, 0.0051) // 表面の位置になるように座標を調整
        node.addChildNode(shapeFaceNode)

        // ノードに物理判定情報を設定
        node.physicsBody = makeShapePhysicsBody(from: pathShapeNode.geometry)

        return node
    }

    private func makePathShapeNode(geometryPath: UIBezierPath) -> SCNNode {

        let geometry = SCNShape(path: geometryPath, extrusionDepth: 0.01 * self.tempGeometryScale)
        let node = SCNNode(geometry: geometry)
        // ベジェパスの座標計算時にいったん、拡大していたので縮小する
        node.scale = SCNVector3(1/self.tempGeometryScale, 1/self.tempGeometryScale, 1/self.tempGeometryScale)
        node.castsShadow = true // ノードの影をつける
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.lightGray
        geometry.materials = [material]
        node.geometry = geometry

        return node
    }

    private func makeShapeFaceNode(from normalizedPath: CGPath, captureImage: CIImage) -> SCNNode? {
        // パスを塗りつぶす画像を生成
        var transform = CGAffineTransform(scaleX: detectSize, y: -detectSize)
        transform = transform.concatenating(CGAffineTransform(translationX: 0, y: detectSize))
        guard let transPath = normalizedPath.copy(using: &transform) else { return nil }

        // パス描画のスケールを端末の種類によらず '1px/pt' に固定する。
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // オフスクリーンでパスを描画する（白で塗りつぶす）
        let pathFillImage = UIGraphicsImageRenderer(size: CGSize(width: self.detectSize, height: self.detectSize), format: format).image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.addPath(transPath)
            context.cgContext.fillPath()
        }
        // 描いたパスをCGImage経由でCIImageに変換
        guard let maskCGImage = pathFillImage.cgImage else { return nil }
        let maskCIImage = CIImage(cgImage: maskCGImage)

        // キャプチャした画像CIImageをCGImageに変換して再度、CIImageに戻す。
        // テクスチャ用のCIImageはCropしているせいだと思われるが、Filterをかけると、CIImage内部に持っている画像のオフセットが無視されて思ったようなフィルタをかけられない。
        let ciContext = CIContext(options: nil)
        guard let captureCGImage = ciContext.createCGImage(captureImage, from: captureImage.extent) else { return nil }
        let captureCIImage = CIImage(cgImage: captureCGImage)

        // パスの内側だけキャプチャした画像を切り抜く
        let filter = CIFilter.multiplyCompositing()
        filter.inputImage = captureCIImage
        filter.backgroundImage = maskCIImage
        guard let texture = filter.outputImage else { return nil }

        // テクスチャを貼るだけのノードを作る
        let textureNode = SCNNode()
        textureNode.geometry = makeShapeFaceGeometory(texture: texture)

        return textureNode
    }

    private func makeShapeFaceGeometory(texture: CIImage) -> SCNGeometry? {
        // パス検出範囲が四隅となる平面ジオメトリ を作成
        guard let lt = leftTop, let rt = rightTop, let lb = leftBottom, let rb = rightBottom else { return nil }
        let vertices = [ lt, rt, lb, rb ]

        let verticeSource = SCNGeometrySource(vertices: vertices)
        let texcoordSource = SCNGeometrySource(textureCoordinates: self.texcoords)
        let geometryElement = SCNGeometryElement(indices: self.indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [verticeSource, texcoordSource], elements: [geometryElement])

        // マテリアルにテクスチャを設定
        let context = CIContext(options: nil)
        let cgImage = context.createCGImage(texture, from: texture.extent)
        let matrial = SCNMaterial()
        matrial.diffuse.contents = cgImage
        geometry.materials = [matrial]

        return geometry
    }

    private func makeShapePhysicsBody(from: SCNGeometry?) -> SCNPhysicsBody? {

        guard let geometry = from else { return nil }
        let bodyMax = geometry.boundingBox.max
        let bodyMin = geometry.boundingBox.min
        let bodyGeometry = SCNBox(width: (bodyMax.x - bodyMin.x).cg * 1/self.tempGeometryScale,
                                  height: (bodyMax.y - bodyMin.y).cg * 1/self.tempGeometryScale,
                                  length: (bodyMax.z - bodyMin.z).cg * 1/self.tempGeometryScale,
                                  chamferRadius: 0.0)
        let bodyShape = SCNPhysicsShape(geometry: bodyGeometry, options: nil)
        let physicsBody = SCNPhysicsBody(type: .dynamic, shape: bodyShape)
        physicsBody.friction = 1.0
        physicsBody.restitution = 0.0
        physicsBody.rollingFriction = 1.0
        physicsBody.angularDamping = 1.0
        physicsBody.linearRestingThreshold = 1.0
        physicsBody.angularRestingThreshold = 1.0

        return physicsBody
    }
}

extension SCNVector3 {
    static func + (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3{
        return SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    static func - (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3{
        return SCNVector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    static func * (lhs: SCNVector3, rhs: CGFloat) -> SCNVector3{
        return SCNVector3(lhs.x * Float(rhs), lhs.y * Float(rhs), lhs.z * Float(rhs))
    }

    static func / (lhs: SCNVector3, rhs: Float) -> SCNVector3{
        return SCNVector3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
    }
}

extension CGPoint {
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint{
        return CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}

extension Float {
    var cg: CGFloat { CGFloat(self) }
}

