import Foundation

/// What Discord shows as being played.
struct DiscordGame: Equatable {
  /// The game's name, or the BASIC the machine booted into. Nil for a
  /// custom boot mode, which has no name worth showing.
  var name: String?
  /// When it booted; Discord counts the elapsed time from here.
  var since: Date
  /// Booted from a disk, CD or tape rather than into BASIC.
  var fromMedia: Bool
}

extension EmulatorViewModel {
  /// The medium a reset boots, in the order the machine picks one: a CD in
  /// the drive wins over a disk (the CD BIOS boots it), and a disk over a
  /// tape, which BASIC loads afterwards.
  private var bootedMediaName: String? {
    if isCDMounted, !cdName.isEmpty { return cdName }
    if let name = currentGameName, !name.isEmpty {
      let stem = (name as NSString).deletingPathExtension
      return stem.isEmpty ? name : stem
    }
    if isTapeMounted, !tapeName.isEmpty { return tapeName }
    return nil
  }

  /// Records that the machine just booted, then tells Discord. Called from a
  /// reset, a URL launch, a state load and app launch: a disk mounted or
  /// swapped while a game runs is not a new game (it is often the same
  /// game's disk B), so mounting a disk never calls this. Rebooting the same
  /// thing keeps its elapsed time.
  func noteGameBooted() {
    let game: DiscordGame
    if let media = bootedMediaName {
      game = DiscordGame(name: media, since: Date(), fromMedia: true)
    } else {
      let mode = _bootModeStorage
      game = DiscordGame(name: mode == .custom ? nil : mode.rawValue, since: Date(), fromMedia: false)
    }
    setDiscordGame(game)
  }

  /// A tape put in under BASIC is about to be loaded from it, which is how
  /// tape software starts. Under a running disk or CD game it is ignored.
  func noteTapeInserted() {
    guard discordGame?.fromMedia != true, !tapeName.isEmpty else { return }
    setDiscordGame(DiscordGame(name: tapeName, since: Date(), fromMedia: true))
  }

  private func setDiscordGame(_ game: DiscordGame) {
    if let current = discordGame, current.name == game.name, current.fromMedia == game.fromMedia {
      // Same thing again: keep the elapsed time.
    } else {
      discordGame = game
    }
    updateDiscordPresence()
  }

  /// Sends what the machine booted to Discord, or clears it when the setting
  /// is off.
  func updateDiscordPresence() {
    guard Settings.shared.discordPresence else {
      discordPresence.stop()
      return
    }
    discordPresence.update(activity: discordGame.map { (details: $0.name, since: $0.since) })
  }
}
