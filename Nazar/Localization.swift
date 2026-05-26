import Foundation

/// Lightweight string table. Bypasses .strings/.lproj because the SPM
/// executableTarget here doesn't bundle resources via the usual route — keeps
/// localization purely in code so it ships as a single binary.
enum L {
    static func t(_ key: String) -> String {
        let lang = currentLang()
        return table[lang]?[key] ?? table["en"]?[key] ?? key
    }

    private static func currentLang() -> String {
        // Honor the user's preferred languages list; fall back to "en".
        if let pref = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init),
           table[pref] != nil { return pref }
        return "en"
    }

    private static let table: [String: [String: String]] = [
        "en": [
            // Menu
            "menu.dashboard": "Dashboard",
            "menu.runCleanup": "Run Cleanup",
            "menu.startupApps": "Startup Apps…",
            "menu.shortcutSet": "Set Shortcut…",
            "menu.shortcutClear": "Remove Shortcut",
            "menu.protectedApps": "Protected Apps…",
            "menu.customize": "Customize…",
            "menu.settings": "Settings",
            "menu.triggerMode": "Trigger Mode",
            "menu.autoDownload": "Auto-download Updates",
            "menu.confirmCleanup": "Confirm Before Cleanup",
            "menu.help": "Help",
            "menu.quickRef": "Quick Reference",
            "menu.replayTutorial": "Show Tutorial Again",
            "menu.feedback": "Send Feedback…",
            "menu.revealLog": "Reveal Log in Finder",
            "menu.checkPerms": "Check Permissions…",
            "menu.quit": "Quit",

            // Cleanup statuses
            "status.closingApps": "Closing apps",
            "status.disk": "Disk",
            "status.updates": "Updates",
            "status.launch": "Launch",
            "status.userCaches": "User Caches",
            "status.systemLogs": "System Logs",
            "status.trash": "Trash",
            "status.xcode": "Xcode Derived Data",
            "status.temp": "Temp Files",
            "status.systemCaches": "System caches",
            "status.done": "Done",

            // Alerts
            "alert.runCleanup.title": "Run Cleanup?",
            "alert.runCleanup.button.run": "Run Cleanup",
            "alert.runCleanup.button.cancel": "Cancel",
            "alert.runCleanup.suppress": "Don't ask again",
            "alert.cleanupComplete": "🧿 Cleanup Complete",
            "alert.cleanupWarnings": "🧿 Cleanup Finished (with warnings)",
            "alert.noStepsSelected": "No steps selected",

            // Dashboard
            "dash.tagline": "Menu bar cleanup, one click.",
            "dash.idle": "Idle",
            "dash.cleaning": "Cleaning…",
            "dash.runningApps": "Running Apps",
            "dash.disk": "Disk",
            "dash.cleanup": "Cleanup",
            "dash.updates": "macOS Updates",
            "dash.appsCount": "%@ open",
            "dash.noApps": "Nothing running.",
            "dash.closeAll": "Close All",
            "dash.used": "Used",
            "dash.free": "Free",
            "dash.addFolder": "Add Folder…",
            "dash.cleanSelected": "Clean Selected",
            "dash.cleaningNow": "Cleaning…",
            "dash.cleanupHint": "Removes caches, logs, and temporary files.",
            "dash.checkUpdates": "Check macOS for Updates",
            "dash.checking": "Checking…",
            "dash.upToDate": "System is up to date",
            "dash.updatesHint": "Tap to see what's available.",
            "dash.downloadAll": "Download All",
            "dash.downloading": "Downloading…",
            "dash.install": "Install",
        ],
        "tr": [
            "menu.dashboard": "Panel",
            "menu.runCleanup": "Temizliği Çalıştır",
            "menu.startupApps": "Açılış Uygulamaları…",
            "menu.shortcutSet": "Kısayol Ata…",
            "menu.shortcutClear": "Kısayolu Kaldır",
            "menu.protectedApps": "Korumalı Uygulamalar…",
            "menu.customize": "Özelleştir…",
            "menu.settings": "Ayarlar",
            "menu.triggerMode": "Tetikleme Modu",
            "menu.autoDownload": "Güncellemeleri Otomatik İndir",
            "menu.confirmCleanup": "Temizlikten Önce Onayla",
            "menu.help": "Yardım",
            "menu.quickRef": "Hızlı Referans",
            "menu.replayTutorial": "Eğitimi Tekrar Göster",
            "menu.feedback": "Geri Bildirim Gönder…",
            "menu.revealLog": "Logu Finder'da Göster",
            "menu.checkPerms": "İzinleri Kontrol Et…",
            "menu.quit": "Çıkış",

            "status.closingApps": "Uygulamalar kapatılıyor",
            "status.disk": "Disk",
            "status.updates": "Güncellemeler",
            "status.launch": "Başlatma",
            "status.userCaches": "Kullanıcı Önbelleği",
            "status.systemLogs": "Sistem Logları",
            "status.trash": "Çöp",
            "status.xcode": "Xcode Türetilmiş Veri",
            "status.temp": "Geçici Dosyalar",
            "status.systemCaches": "Sistem önbelleği",
            "status.done": "Bitti",

            "alert.runCleanup.title": "Temizliği Çalıştır?",
            "alert.runCleanup.button.run": "Temizliği Çalıştır",
            "alert.runCleanup.button.cancel": "İptal",
            "alert.runCleanup.suppress": "Bir daha sorma",
            "alert.cleanupComplete": "🧿 Temizlik Tamamlandı",
            "alert.cleanupWarnings": "🧿 Temizlik Uyarılarla Bitti",
            "alert.noStepsSelected": "Hiçbir adım seçilmemiş",

            "dash.tagline": "Tek tıkla menü çubuğu temizliği.",
            "dash.idle": "Beklemede",
            "dash.cleaning": "Temizleniyor…",
            "dash.runningApps": "Açık Uygulamalar",
            "dash.disk": "Disk",
            "dash.cleanup": "Temizlik",
            "dash.updates": "macOS Güncellemeleri",
            "dash.appsCount": "%@ açık",
            "dash.noApps": "Çalışan uygulama yok.",
            "dash.closeAll": "Hepsini Kapat",
            "dash.used": "Kullanılan",
            "dash.free": "Boş",
            "dash.addFolder": "Klasör Ekle…",
            "dash.cleanSelected": "Seçilenleri Temizle",
            "dash.cleaningNow": "Temizleniyor…",
            "dash.cleanupHint": "Önbellek, log ve geçici dosyaları siler.",
            "dash.checkUpdates": "macOS Güncellemelerini Kontrol Et",
            "dash.checking": "Kontrol ediliyor…",
            "dash.upToDate": "Sistem güncel",
            "dash.updatesHint": "Mevcut güncellemeler için tıkla.",
            "dash.downloadAll": "Tümünü İndir",
            "dash.downloading": "İndiriliyor…",
            "dash.install": "Kur",
        ],
    ]
}
