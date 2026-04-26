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

extension SystemLanguageModel.Availability.UnavailableReason {
    func localizedDescription(language: AppLanguage) -> String {
        switch self {
        case .deviceNotEligible:
            return L10n.string(.providerAppleIntelligenceDeviceNotEligible, language: language)
        case .appleIntelligenceNotEnabled:
            return L10n.string(.providerAppleIntelligenceNotEnabled, language: language)
        case .modelNotReady:
            return L10n.string(.providerAppleIntelligenceModelNotReady, language: language)
        @unknown default:
            return L10n.string(.providerAppleIntelligenceModelNotReady, language: language)
        }
    }
}
