import Foundation

struct CloudContinuation: Sendable {
    let identity: CloudIdentity
    let position: CloudPosition
    let folder: URL?

    @MainActor
    static func read(_ activity: NSUserActivity) -> Self? {
        guard activity.activityType == CloudEnvironment.activityType,
              let info = activity.userInfo, info["version"] as? Int == 1,
              let id = (info["document"] as? String).flatMap(UUID.init(uuidString:)),
              let generation = (info["generation"] as? String).flatMap(UUID.init(uuidString:)),
              let data = info["position"] as? Data, data.count <= 8_192,
              let position = try? JSONDecoder().decode(CloudPosition.self, from: data) else { return nil }
        let folder = info["folderURL"] as? URL
        guard folder == nil || folder?.isFileURL == true else { return nil }
        return Self(identity: CloudIdentity(id: id, generation: generation), position: position.sanitized, folder: folder)
    }

    @MainActor
    static func configure(_ activity: NSUserActivity, item: CloudItem, position: CloudPosition, folder: URL?) {
        activity.title = "Read \(item.name)"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        var bounded = position.sanitized
        var encoded = (try? JSONEncoder().encode(bounded)) ?? Data()
        for field in 0..<3 where encoded.count > 8_192 {
            if field == 0 { bounded.heading = nil }
            else if field == 1 { bounded.revision = nil }
            else { bounded.path = nil }
            encoded = (try? JSONEncoder().encode(bounded)) ?? Data()
        }
        var info: [AnyHashable: Any] = [
            "version": 1, "document": item.id.uuidString, "generation": item.generation.uuidString,
            "position": encoded
        ]
        if let folder, folder.isFileURL { info["folderURL"] = folder }
        activity.userInfo = info
        activity.requiredUserInfoKeys = ["version", "document", "generation", "position"]
        activity.needsSave = true
    }
}

enum CloudReadingScript {
    static let tracking = #"""
    (() => {
      let timer;
      const blocks = () => [...document.querySelectorAll("article h1, article h2, article h3, article h4, article h5, article h6, article p, article pre, article table, article blockquote")];
      window.folioReadingLocation = () => {
        const all = blocks();
        let index = all.findIndex(node => node.getBoundingClientRect().bottom > 12);
        if (index < 0) index = Math.max(0, all.length - 1);
        const rect = all[index]?.getBoundingClientRect();
        const heading = [...document.querySelectorAll("article h1[id], article h2[id], article h3[id], article h4[id], article h5[id], article h6[id]")]
          .filter(node => node.getBoundingClientRect().top <= 24).at(-1)?.id ?? null;
        return {heading, block: all.length ? index : null,
          blockOffset: rect ? Math.max(0, Math.min(1, -rect.top / Math.max(1, rect.height))) : 0,
          progress: Math.max(0, Math.min(1, window.scrollY / Math.max(1, document.documentElement.scrollHeight - window.innerHeight)))};
      };
      window.folioResumeReading = (position, sameRevision) => {
        const all = blocks();
        if (sameRevision && position.progress === 0 && position.block === 0 && position.blockOffset === 0) {
          window.scrollTo(0, 0);
        } else if (sameRevision && Number.isInteger(position.block) && all[position.block]) {
          const rect = all[position.block].getBoundingClientRect();
          window.scrollTo(0, window.scrollY + rect.top + rect.height * position.blockOffset);
        } else if (position.heading && document.getElementById(position.heading)) {
          document.getElementById(position.heading).scrollIntoView({block: "start"});
        } else {
          window.scrollTo(0, position.progress * Math.max(0, document.documentElement.scrollHeight - window.innerHeight));
        }
      };
      window.addEventListener("scroll", () => {
        clearTimeout(timer);
        timer = setTimeout(() => window.webkit?.messageHandlers?.folioReading?.postMessage(window.folioReadingLocation()), 250);
      }, {passive: true});
    })();
    """#

    static func position(_ body: Any, revision: String?) -> CloudPosition? {
        guard var object = body as? [String: Any] else { return nil }
        if let heading = object["heading"] as? String, heading.utf8.count > 4_096 { object["heading"] = nil }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 8_192,
              var position = try? JSONDecoder().decode(CloudPosition.self, from: data) else { return nil }
        position.revision = revision
        return position.sanitized
    }

    static func arguments(_ position: CloudPosition, revision: String?) -> [String: Any] {
        let data = (try? JSONEncoder().encode(position.sanitized)) ?? Data()
        return ["position": (try? JSONSerialization.jsonObject(with: data)) ?? [:],
                "sameRevision": position.revision != nil && position.revision == revision]
    }
}
