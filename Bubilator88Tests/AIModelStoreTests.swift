import Foundation
import Testing
@testable import Bubilator88

/// Covers `AIModelStore`'s install path: an archive is accepted only when it
/// matches the manifest exactly, and lookups only ever find the manifest's
/// install. The network leg (`download`) is URLSession plumbing on top of
/// `install` and is not exercised here.
struct AIModelStoreTests {

  private static let modelName = "TestModel_x2"

  /// A fresh store rooted in its own temporary directory.
  private func makeStore() -> AIModelStore {
    AIModelStore(root: URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
      .appending(component: "AIModelStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory))
  }

  /// Zips a fake `<name>.mlmodelc` directory the way
  /// `scripts/package_ai_model.sh` does, and returns the zip with a manifest
  /// entry describing it.
  private func makeArchive(payload: String = "weights",
                           topLevelName: String = "\(modelName).mlmodelc") throws -> (URL, DownloadableAIModel) {
    let work = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
      .appending(component: "AIModelStoreTests-src-\(UUID().uuidString)", directoryHint: .isDirectory)
    let bundle = work.appending(component: topLevelName, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle.appending(component: "weights"),
                                            withIntermediateDirectories: true)
    try Data(payload.utf8).write(to: bundle.appending(component: "weights/weight.bin"))
    try Data("{}".utf8).write(to: bundle.appending(component: "metadata.json"))

    let zip = work.appending(component: "model.zip")
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noacl",
                         bundle.path, zip.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let size = try #require(FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)
    let model = DownloadableAIModel(name: Self.modelName,
                                    url: URL(string: "https://example.invalid/model.zip")!,
                                    sha256: try AIModelStore.sha256Hex(of: zip),
                                    byteCount: size.int64Value)
    return (zip, model)
  }

  @Test("sha256Hex matches the known digest of \"abc\"")
  func sha256KnownVector() throws {
    let file = URL(filePath: NSTemporaryDirectory()).appending(component: "abc-\(UUID().uuidString)")
    try Data("abc".utf8).write(to: file)
    #expect(try AIModelStore.sha256Hex(of: file)
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test("a matching archive installs and is found by lookup")
  func installMatchingArchive() async throws {
    let store = makeStore()
    let (zip, model) = try makeArchive()
    #expect(!store.isInstalled(model))

    try await store.install(archiveAt: zip, for: model)

    let url = try #require(store.installedModelURL(for: model))
    #expect(url.lastPathComponent == "\(Self.modelName).mlmodelc")
    #expect(url.deletingLastPathComponent().lastPathComponent == model.installDirectoryName)
    #expect(FileManager.default.fileExists(atPath: url.appending(component: "weights/weight.bin").path))
  }

  @Test("an archive whose hash differs from the manifest is rejected")
  func rejectHashMismatch() async throws {
    let store = makeStore()
    let (zip, good) = try makeArchive()
    let tampered = DownloadableAIModel(name: good.name, url: good.url,
                                       sha256: String(repeating: "0", count: 64),
                                       byteCount: good.byteCount)

    await #expect(throws: AIModelStore.StoreError.self) {
      try await store.install(archiveAt: zip, for: tampered)
    }
    #expect(!store.isInstalled(tampered))
    #expect(!store.isInstalled(good))
  }

  @Test("an archive whose size differs from the manifest is rejected")
  func rejectSizeMismatch() async throws {
    let store = makeStore()
    let (zip, good) = try makeArchive()
    let wrongSize = DownloadableAIModel(name: good.name, url: good.url,
                                        sha256: good.sha256, byteCount: good.byteCount + 1)

    await #expect(throws: AIModelStore.StoreError.self) {
      try await store.install(archiveAt: zip, for: wrongSize)
    }
    #expect(!store.isInstalled(wrongSize))
  }

  @Test("an archive without the named model is rejected and leaves nothing behind")
  func rejectWrongContents() async throws {
    let store = makeStore()
    let (zip, model) = try makeArchive(topLevelName: "SomethingElse.mlmodelc")

    await #expect(throws: AIModelStore.StoreError.self) {
      try await store.install(archiveAt: zip, for: model)
    }
    #expect(!store.isInstalled(model))
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []
    #expect(leftovers.isEmpty)
  }

  @Test("installing a new version removes the previous one")
  func newVersionReplacesOld() async throws {
    let store = makeStore()
    let (zipV1, v1) = try makeArchive(payload: "v1")
    let (zipV2, v2) = try makeArchive(payload: "v2")
    #expect(v1.installDirectoryName != v2.installDirectoryName)

    try await store.install(archiveAt: zipV1, for: v1)
    try await store.install(archiveAt: zipV2, for: v2)

    #expect(!store.isInstalled(v1))
    #expect(store.isInstalled(v2))
  }

  @Test("a stray directory not named by the manifest's hash is never found")
  func strayDirectoryIgnored() throws {
    let store = makeStore()
    let (_, model) = try makeArchive()
    let stray = store.root
      .appending(component: "\(Self.modelName)-000000000000", directoryHint: .isDirectory)
      .appending(component: "\(Self.modelName).mlmodelc", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

    #expect(!store.isInstalled(model))
  }

  @Test("download fetches, verifies and installs through URLSession")
  func downloadFromFileURL() async throws {
    let store = makeStore()
    let (zip, local) = try makeArchive()
    let model = DownloadableAIModel(name: local.name, url: zip,
                                    sha256: local.sha256, byteCount: local.byteCount)

    try await store.download(model) { _ in }

    #expect(store.isInstalled(model))
  }

  @Test("remove deletes every installed version")
  func removeDeletesInstall() async throws {
    let store = makeStore()
    let (zip, model) = try makeArchive()
    try await store.install(archiveAt: zip, for: model)

    try store.remove(model)

    #expect(!store.isInstalled(model))
  }

  @Test("the manifest names only models the app does not bundle")
  func manifestModelsAreNotBundled() {
    for model in AIModelStore.downloadableModels {
      #expect(Bundle.main.url(forResource: model.name, withExtension: "mlmodelc") == nil)
      #expect(model.sha256.count == 64)
    }
  }
}
