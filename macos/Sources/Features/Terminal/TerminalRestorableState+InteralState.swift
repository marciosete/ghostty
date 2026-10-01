import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // MARK: - Tab sidebar
        // Optional, so state saved without it still decodes.
        let userTabGroup: UserTabGroup?

        // MARK: - Speech
        // The ElevenLabs voice picked for the session. Optional, like the group.
        let speechVoiceID: String?

        // MARK: - Folders
        // The tab's folder, and every folder open in its sidebar, so a folder with no
        // sessions comes back too. Optional, like the group.
        let userTabFolder: UserTabFolder?
        let sidebarFolders: [UserTabFolder]?

        // The folder groups those folders are in. Optional, like the folders.
        let sidebarFolderGroups: [UserTabFolderGroup]?
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        let window = controller.window as? TerminalWindow
        let folders = UserTabFolderStore.shared
        let sidebarFolders = window.map { $0.folderSpace.folderIDs.compactMap { folders[$0] } }
        var folderGroupIDs: [UUID] = []
        for folder in sidebarFolders ?? [] {
            guard let groupID = folder.groupID, !folderGroupIDs.contains(groupID) else { continue }
            folderGroupIDs.append(groupID)
        }
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: window?.tabColor,
            titleOverride: controller.titleOverride,
            userTabGroup: UserTabGroupStore.shared[window?.userTabGroupID],
            speechVoiceID: window?.speechVoiceID,
            userTabFolder: folders[window?.userTabFolderID],
            sidebarFolders: sidebarFolders,
            sidebarFolderGroups: folderGroupIDs.compactMap { UserTabFolderGroupStore.shared[$0] },
        )
    }
}
