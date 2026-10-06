import Bubilator88Core
import SwiftUI

/// Cheats Menu: the 88PAR groups of the cheat set for the mounted disks, and
/// where sets come from (bundled presets, `.pat` files).
struct CheatCommands: Commands {
  let viewModel: EmulatorViewModel

  var body: some Commands {
    CommandMenu("Cheats") {
      Group {
        if let set = viewModel.activeCheatSet {
          Text(set.name).disabled(true)
          let groups = CheatStore.shared.groups(of: set)
          ForEach(groups.indices, id: \.self) { index in
            Toggle(groups[index].name.isEmpty ? PATFile.unnamedGroupName : groups[index].name,
                   isOn: Binding(
                     get: { viewModel.isCheatGroupEnabled(index) },
                     set: { viewModel.setCheatGroup(index, enabled: $0) }))
          }
          Divider()
          Button("Disable All Cheats") {
            viewModel.disableAllCheats()
          }
          .disabled(set.enabledGroups.isEmpty)
          Divider()
        }
        let noDisk = viewModel.drive0Info == nil && viewModel.drive1Info == nil
        Menu("Presets") {
          ForEach(CheatStore.shared.presets, id: \.title) { preset in
            Button(preset.title) {
              viewModel.useCheatPreset(preset)
            }
          }
        }
        .disabled(noDisk)
        Button("Import Cheat File...") {
          viewModel.openCheatFile()
        }
        .disabled(noDisk)
      }
      .disabled(!viewModel.allows(.media))
    }
  }
}
