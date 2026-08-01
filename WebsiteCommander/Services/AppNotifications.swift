import Foundation

extension Notification.Name {
    static let refreshPreview = Notification.Name("refreshPreview")
    static let requestOpenInVSCode = Notification.Name("requestOpenInVSCode")
    static let requestRefreshPreview = Notification.Name("requestRefreshPreview")
    static let requestAddSite = Notification.Name("requestAddSite")
    static let requestDebug = Notification.Name("requestDebug")
    static let requestPalette = Notification.Name("requestPalette")
    static let requestAgentPreview = Notification.Name("requestAgentPreview")
    static let requestAgentPreviewFromEngine = Notification.Name("requestAgentPreviewFromEngine")
    static let requestConversations = Notification.Name("requestConversations")
    static let requestAgentSend = Notification.Name("requestAgentSend")
    static let requestAgentStop = Notification.Name("requestAgentStop")
    static let requestApproveAll = Notification.Name("requestApproveAll")
    static let requestAgentSendFromMenu = Notification.Name("requestAgentSendFromMenu")
    static let requestAgentStopFromMenu = Notification.Name("requestAgentStopFromMenu")
    static let requestApproveAllFromMenu = Notification.Name("requestApproveAllFromMenu")
}
