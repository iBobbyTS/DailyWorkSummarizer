import Foundation
import FoundationModels

struct AppleIntelligenceStatus: Equatable {
    let availability: SystemLanguageModel.Availability
    let supportedAppLanguages: [AppLanguage]
    let currentLanguage: AppLanguage

    var unavailableReason: SystemLanguageModel.Availability.UnavailableReason? {
        guard case .unavailable(let reason) = availability else {
            return nil
        }
        return reason
    }

    var isSelectable: Bool {
        unavailableReason == nil
    }

    var currentLanguageSupported: Bool {
        supportedAppLanguages.contains(currentLanguage)
    }
}

enum AppleIntelligenceSupport {
    static func currentStatus(for currentLanguage: AppLanguage) -> AppleIntelligenceStatus {
        let model = SystemLanguageModel.default
        let supportedAppLanguages = AppLanguage.allCases.filter { model.supportsLocale($0.locale) }
        return AppleIntelligenceStatus(
            availability: model.availability,
            supportedAppLanguages: supportedAppLanguages,
            currentLanguage: currentLanguage
        )
    }
}
