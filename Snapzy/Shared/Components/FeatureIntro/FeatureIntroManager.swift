import Foundation

@MainActor
public final class FeatureIntroManager {
  public static let shared = FeatureIntroManager()
  private init() {}

  // Кампании исходного проекта не относятся к OwnShot.
  public func getPendingCampaign() -> FeatureIntroCampaign? { nil }
  public func showCampaign(_ campaign: FeatureIntroCampaign) {}
}
