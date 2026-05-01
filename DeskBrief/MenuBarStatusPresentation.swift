import Foundation

enum MenuBarStatusPresentation {
    static func currentModelLine(profile: ModelProfileSettings, language: AppLanguage) -> String {
        L10n.string(
            .menuCurrentStatusCurrentModel,
            language: language,
            arguments: [displayModelName(for: profile, language: language)]
        )
    }

    static func analysisRunningTitle(language: AppLanguage) -> String {
        L10n.string(.menuCurrentStatusRunningScreenshotAnalysis, language: language)
    }

    static func analysisProgressLine(
        state: AnalysisRuntimeState,
        startedAt: Date,
        language: AppLanguage
    ) -> String {
        if state.isStopping {
            let stoppingStage = state.stoppingStage ?? .stoppingGeneration
            return L10n.string(
                stoppingStage.statusSummaryLocalizationKey,
                language: language,
                arguments: [
                    L10n.statusDateFormatter(language: language).string(from: startedAt),
                    state.completedCount,
                    state.totalCount
                ]
            )
        }

        return L10n.string(
            .menuSummaryAnalyzing,
            language: language,
            arguments: [
                L10n.statusDateFormatter(language: language).string(from: startedAt),
                state.completedCount,
                state.totalCount
            ]
        )
    }

    static func summaryRunningTitle(language: AppLanguage) -> String {
        L10n.string(.menuCurrentStatusRunningWorkContentSummary, language: language)
    }

    static func summaryProgressLine(state: DailyReportSummaryRuntimeState, language: AppLanguage) -> String {
        L10n.string(
            .menuCurrentStatusProgress,
            language: language,
            arguments: [state.progressPercentage]
        )
    }

    static func forceUnloadButtonTitle(for target: ForceUnloadTarget, language: AppLanguage) -> String {
        L10n.string(target.menuTitleKey, language: language)
    }

    static func stopCurrentWorkConfirmation(language: AppLanguage) -> String {
        L10n.string(.menuForceUnloadConfirmStopAnalysis, language: language)
    }

    static func lifecycleDisabledConfirmation(appName: String, language: AppLanguage) -> String {
        L10n.string(
            .menuForceUnloadConfirmLifecycleDisabled,
            language: language,
            arguments: [appName]
        )
    }

    static func displayModelName(for profile: ModelProfileSettings, language: AppLanguage) -> String {
        let trimmedName = profile.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        return profile.provider.title(in: language)
    }
}
