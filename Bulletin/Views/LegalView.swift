import SwiftUI

enum LegalDocument: String, Identifiable {
    case privacy
    case terms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return "Privacy Policy"
        case .terms: return "Terms of Service"
        }
    }

    var subtitle: String {
        switch self {
        case .privacy: return "What Bulletin collects, why, and the choices you have."
        case .terms: return "The rules for using Bulletin and attending events."
        }
    }

    var sections: [LegalSection] {
        switch self {
        case .privacy: return LegalText.privacy
        case .terms: return LegalText.terms
        }
    }
}

struct LegalSection: Identifiable {
    let id = UUID()
    let heading: String
    let paragraphs: [String]
}

struct LegalView: View {
    let document: LegalDocument

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    ForEach(document.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.heading)
                                .font(.headline)
                                .foregroundStyle(AppTheme.textPrimary)

                            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    contactCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .background(AppTheme.secondaryBG)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: document == .privacy ? "hand.raised.fill" : "doc.text.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.blueMatte)
                .padding(.bottom, 2)

            Text(document.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)

            Text(document.subtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)

            Text("Last updated \(LegalConfig.effectiveDate)")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.separator.opacity(0.6), lineWidth: 1)
        )
    }

    private var contactCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Questions?")
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text("Contact \(LegalConfig.operatorName) about this policy or your account.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
            if let url = URL(string: "mailto:\(LegalConfig.supportEmail)") {
                Link(LegalConfig.supportEmail, destination: url)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.blueMatte)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.blueMatte.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Copy

private enum LegalText {

    static let privacy: [LegalSection] = [
        LegalSection(
            heading: "Overview",
            paragraphs: [
                "Bulletin helps people discover, post, and join small local events. This Privacy Policy explains what information we collect, why we collect it, how it is used, and the choices you have. It applies to the Bulletin iOS app and the services that support it.",
                "\(LegalConfig.appName) is operated by \(LegalConfig.operatorName) (\"we\", \"us\", or \"our\"). We are the controller of the personal information described in this policy."
            ]
        ),
        LegalSection(
            heading: "Information you give us",
            paragraphs: [
                "• Account information. We collect your email address and a Firebase user identifier when you create an account. Your password is sent directly to Firebase Authentication; we do not receive, see, or store it. Your phone number is stored only on your device and is never sent to us; only a one-way hash of it is published so contacts can match your account.",
                "• Event content. When you post an event we collect the title, description, category, address, date and time, entry-fee setting, photos or banner image, and the organizer name shown on the event. Organizer names are derived from the part of your email before the @ symbol (for example, jane@example.com becomes \"jane\").",
                "• Public event information. Event pages, including the event address and photos, are public to people using Bulletin, including people who are not signed in. Do not post anything in an event that you do not want to be public.",
                "• Support messages. If you email us, we receive your email address and the contents of your message so we can respond."
            ]
        ),
        LegalSection(
            heading: "Device features you choose to use",
            paragraphs: [
                "• Location. With your permission, Bulletin uses your precise location to center the feed and find nearby events. Location is processed on your device for searching and filtering. Saved locations are stored locally on your device. To decide whether to send you a notification about a friend's event, Bulletin stores your current search center and radius with your account; this notification area is private and is not shown to other users. If you post an event, the address you enter is public.",
                "• Contacts. With your permission, Bulletin reads names, email addresses, phone numbers, and contact photos from your contacts on your device. It computes one-way SHA-256 hashes of normalized forms of each email address and phone number and compares those hashes locally against a lookup table of hashed account values that it downloads. We do not receive your address book, contact names, contact photos, or the raw email addresses and phone numbers in it. The friend names, phone numbers, and photos shown in the app are matched and displayed on your device. To let your contacts find you, Bulletin publishes one-way hashes of your own account email and phone number (never the raw values) to that lookup table. To deliver friend-event notifications, Bulletin also stores the account IDs of friends you matched. It does not upload their names, phone numbers, email addresses, or contact photos.",
                "• Notifications. If you allow notifications, Bulletin registers a device token with Apple Push Notification service and stores it with your account so we can deliver alerts about friends' events. You can turn notifications off at any time in iOS Settings.",
                "• Photos. If you add a banner or pictures to an event, Bulletin receives the images you select and stores them with that public event.",
                "• You can change or revoke location and contacts access at any time in iOS Settings. Revoking a permission does not delete information already posted."
            ]
        ),
        LegalSection(
            heading: "Information collected automatically",
            paragraphs: [
                "Firebase Authentication and the Firebase Realtime Database process technical information needed to run and protect the service, such as IP address, device and operating-system type, app version, timestamps, and request logs. This information is used for authentication, security, abuse prevention, and troubleshooting.",
                "We do not use third-party advertising or analytics SDKs, we do not track you across other apps or websites, and we do not sell personal information. Apple may collect crash and usage diagnostics if you have chosen to share them with app developers in iOS Settings."
            ]
        ),
        LegalSection(
            heading: "How we use information",
            paragraphs: [
                "We use information to create and authenticate accounts; show events on the feed; power search, categories, distance filters, saved locations, and friend matching; record RSVPs; keep events and attendance lists working; respond to support requests; detect and prevent abuse; enforce our Terms of Service; and comply with legal obligations.",
                "We do not sell or rent your personal information, and we do not use it for cross-context behavioral advertising."
            ]
        ),
        LegalSection(
            heading: "Legal bases for processing",
            paragraphs: [
                "If you are in the European Economic Area or the United Kingdom, we rely on these legal bases: performance of a contract when we provide the app and the features you request; our legitimate interests in operating, securing, and improving Bulletin; your consent for optional device features such as precise location and contacts; and legal obligations when we must retain or disclose information.",
                "You may withdraw consent for location or contacts at any time in iOS Settings. Withdrawing consent does not affect processing that already happened."
            ]
        ),
        LegalSection(
            heading: "How information is shared",
            paragraphs: [
                "• Google Firebase. We use Firebase Authentication and the Firebase Realtime Database, provided by Google, to store accounts, events, RSVPs, the hashed contact directory, friend-notification subscriptions, and push device tokens. Firebase processes this information on our behalf. Data is stored in the United States. See Google's privacy policy at https://policies.google.com/privacy.",
                "• Apple Push Notification service. If you allow notifications, Apple delivers alerts to your device using a device token. Apple processes delivery data under its privacy policy at https://www.apple.com/privacy.",
                "• Apple MapKit. Address searches, autocomplete, and directions use Apple Maps services. Apple processes the searches you make there under its privacy policy at https://www.apple.com/privacy.",
                "• Other people using Bulletin. Public event content is visible to anyone using the app. Signed-in users can see the attendance list for an event, which shows which accounts are going. If you join an event, your attendance may be visible to other signed-in users, including friends who have matched your contact.",
                "• Service providers and legal reasons. We may share information with vendors that host or support the service, or when required by law, legal process, or to protect the rights, safety, and security of users, the public, or us. If Bulletin is involved in a merger, acquisition, or sale of assets, information may be transferred as part of that transaction.",
                "We do not sell your personal information and we do not share it for cross-context behavioral advertising."
            ]
        ),
        LegalSection(
            heading: "Data retention",
            paragraphs: [
                "We keep account information while your account exists. The phone number you enter stays in the iOS Keychain on your device until you change it or delete your account. Events stay in the database until you delete them, until we remove them for a policy or safety reason, or until your account is deleted. RSVPs stay until you leave the event or delete your account. Friend-notification subscriptions, notification areas, and push device tokens stay until you sign out, turn notifications off, or delete your account. Support messages are kept only as long as needed to respond and for reasonable recordkeeping.",
                "When you use Delete Account in Settings, we delete your profile, hosted events, RSVPs, contact-directory hashes, friend-notification subscriptions, notification area, and push device tokens, and then delete your Firebase Authentication record. The phone number is removed from this device. Some residual copies may remain in backups or logs for a limited period before they are overwritten. We may retain limited information when the law requires it or to resolve disputes and prevent abuse."
            ]
        ),
        LegalSection(
            heading: "Security",
            paragraphs: [
                "Data travels over encrypted HTTPS connections. Firebase security rules restrict access to user records, auth tokens are stored in the iOS Keychain, and contact emails and phone numbers used for friend matching are hashed on the device. Push device tokens and friend-notification subscriptions are stored under rules that only allow the owner to write them. No method of transmission or storage is completely secure, so we cannot guarantee absolute security.",
                "If we become aware of a breach affecting your personal information, we will notify you and the relevant authorities as required by applicable law."
            ]
        ),
        LegalSection(
            heading: "Your choices and rights",
            paragraphs: [
                "You can update location, contacts, and notification permissions in iOS Settings, leave events you have joined, and delete your account and its data from Settings → Delete Account. You can also contact us to request access to, correction of, or deletion of your personal information, or to ask a question about this policy.",
                "We may need to verify your identity before acting on a request. You may use an authorized agent where the law allows it. We will not discriminate against you for exercising a privacy right.",
                "If you are in California, you have the right to know the categories and specific pieces of personal information we collect, the right to delete it, the right to correct it, the right to opt out of the sale or sharing of personal information, and the right to limit the use of sensitive personal information. We do not sell or share personal information for cross-context behavioral advertising and we do not collect sensitive personal information for the purpose of inferring characteristics. To exercise a right, contact us at the email below.",
                "If you are in the EEA or UK, you also have the right to restrict or object to processing, to data portability, and to lodge a complaint with your local supervisory authority. We process information in the United States; where required, transfers are covered by appropriate safeguards such as the standard contractual clauses used by our providers."
            ]
        ),
        LegalSection(
            heading: "Children's privacy",
            paragraphs: [
                "Bulletin is not directed to children under 13, and you may not create an account if you are under 13. If you are under 18, use Bulletin only with the permission of a parent or guardian. We do not knowingly collect personal information from children under 13.",
                "If you believe a child under 13 has created an account or posted information, contact us and we will delete the account and associated content."
            ]
        ),
        LegalSection(
            heading: "International users",
            paragraphs: [
                "Bulletin is operated in the United States, and information is processed and stored there. Privacy laws in the United States may differ from those in your country. If you use Bulletin from another country, you understand that your information will be transferred to and processed in the United States."
            ]
        ),
        LegalSection(
            heading: "Changes to this policy",
            paragraphs: [
                "We may update this policy as the app changes. When we do, we will change the \"Last updated\" date above. If a change is material, we will provide a notice in the app or by email before it takes effect. Continuing to use Bulletin after an update means you accept the revised policy."
            ]
        ),
        LegalSection(
            heading: "Contact",
            paragraphs: [
                "Questions, requests, or concerns about privacy can be sent to \(LegalConfig.supportEmail). Please include the email address associated with your Bulletin account so we can find it."
            ]
        )
    ]

    static let terms: [LegalSection] = [
        LegalSection(
            heading: "Acceptance of these Terms",
            paragraphs: [
                "These Terms of Service (\"Terms\") are a legal agreement between you and \(LegalConfig.operatorName) (\"we\", \"us\", or \"our\") governing your use of the Bulletin app and related services (\"Bulletin\"). By creating an account, signing in, or using Bulletin, you agree to these Terms and to our Privacy Policy.",
                "If you do not agree, do not use Bulletin."
            ]
        ),
        LegalSection(
            heading: "Eligibility",
            paragraphs: [
                "You must be at least 13 years old to use Bulletin. If you are between 13 and the age of majority where you live, you may use Bulletin only with the involvement and permission of a parent or guardian. By using Bulletin, you represent that you meet these requirements.",
                "You may not use Bulletin if you have previously been removed for violating these Terms or if applicable law prohibits you from using the service."
            ]
        ),
        LegalSection(
            heading: "Your account",
            paragraphs: [
                "You are responsible for the information you provide, for keeping your password confidential, and for all activity that happens under your account. Provide accurate information and keep it up to date. Tell us promptly if you believe your account has been compromised.",
                "We may suspend or terminate accounts that violate these Terms, create risk for other people, or are required to be removed by law."
            ]
        ),
        LegalSection(
            heading: "Your content",
            paragraphs: [
                "You keep ownership of the text, photos, and other content you post. By posting content, you grant us a worldwide, non-exclusive, royalty-free license to host, store, reproduce, display, and distribute that content as needed to operate, promote, and improve Bulletin. This license ends when you delete the content or your account, except for copies that remain in backups or were shared with others before deletion.",
                "You represent that you own or have permission to use everything you post, including photos of other people, and that your content does not violate anyone's rights or the law. Do not post content that is false, misleading, or intended to deceive.",
                "Event pages and the information in them are public. Do not post private information, such as a home address, if you do not want it to be public."
            ]
        ),
        LegalSection(
            heading: "Events and organizer responsibilities",
            paragraphs: [
                "Bulletin is a platform for discovering and organizing events. We are not the organizer, host, seller, venue, or insurer of any event, and we do not endorse any event or organizer. The person who posts an event is solely responsible for it.",
                "Organizers must: have the authority to host the event; provide accurate details about the time, place, cost, and nature of the event; obtain any permits, licenses, insurance, and permissions required by law; comply with all applicable laws and safety requirements; and treat attendees lawfully and respectfully.",
                "We may remove or restrict any event that appears to violate these Terms, create a safety risk, or be unlawful, without prior notice."
            ]
        ),
        LegalSection(
            heading: "Attendance and assumption of risk",
            paragraphs: [
                "Bulletin helps people connect, but it does not screen organizers or attendees. We do not run background checks, verify identities, inspect venues, or supervise events. You are responsible for your own decisions about which events to attend and whom to meet.",
                "In-person events involve inherent risks. By attending an event you accept those risks, including the risk of injury, property damage, and interactions with people you do not know. Use good judgment, meet in public places, tell someone where you are going, and call 911 in an emergency. To the fullest extent permitted by law, you release us from claims arising from events you choose to host or attend."
            ]
        ),
        LegalSection(
            heading: "Prohibited conduct",
            paragraphs: [
                "You may not:",
                "• post or attend events that are illegal, dangerous, fraudulent, or intended to harm someone;",
                "• harass, threaten, intimidate, stalk, or discriminate against anyone;",
                "• post hateful, violent, sexually exploitative, or otherwise objectionable content;",
                "• impersonate another person or misrepresent your affiliation with anyone;",
                "• post spam, chain messages, scams, or ads unrelated to a real local event;",
                "• collect or share another person's private information without consent;",
                "• upload malware, attempt to access accounts or data you are not authorized to access, probe or circumvent security rules, scrape the service, or interfere with its operation;",
                "• use Bulletin to violate any law, including laws about minors, weapons, alcohol, gambling, or the sale of goods;",
                "• create accounts through automated means or use the service to send unsolicited commercial messages.",
                "We may remove content and suspend or terminate accounts for violations."
            ]
        ),
        LegalSection(
            heading: "Location, contacts, and permissions",
            paragraphs: [
                "Some features ask for access to your location, contacts, or notifications. These permissions are optional, and you can change them in iOS Settings. If you grant contacts access, Bulletin matches hashed email addresses and phone numbers on your device as described in the Privacy Policy. If you grant location access, Bulletin uses your location to find nearby events and, for push notifications, stores your selected search area with your account. If you allow notifications, Bulletin may alert you when a matched friend posts an event nearby. You are responsible for the addresses you post and for respecting other people's privacy."
            ]
        ),
        LegalSection(
            heading: "Intellectual property",
            paragraphs: [
                "Bulletin, its name, logo, design, and software are owned by us or our licensors and are protected by intellectual property laws. We grant you a limited, non-exclusive, non-transferable, revocable license to use the app for personal, non-commercial use in accordance with these Terms and the App Store rules.",
                "You may not copy, modify, distribute, sell, reverse engineer, or create derivative works from the app except as allowed by law or with our written permission. All rights not expressly granted are reserved."
            ]
        ),
        LegalSection(
            heading: "Copyright complaints",
            paragraphs: [
                "If you believe content on Bulletin infringes your copyright, contact us at \(LegalConfig.supportEmail) with a description of the work, the location of the allegedly infringing content, your contact information, a statement that you have a good-faith belief the use is unauthorized, and a statement that the information is accurate. We may remove content and terminate repeat infringers."
            ]
        ),
        LegalSection(
            heading: "Third-party services",
            paragraphs: [
                "Bulletin relies on services provided by Google Firebase and Apple, including authentication, data storage, maps, and address search. Those services are governed by their own terms and privacy policies. We are not responsible for third-party services or for links to other websites or apps.",
                "If you download Bulletin from the Apple App Store, you must also comply with the App Store Terms of Service."
            ]
        ),
        LegalSection(
            heading: "Termination",
            paragraphs: [
                "You may stop using Bulletin at any time and may delete your account in Settings. We may suspend or terminate your access, remove content, or delete your account if you violate these Terms, create risk, or if we are required to do so by law.",
                "Sections that by their nature should survive termination, including ownership, disclaimers, limitation of liability, indemnification, and governing law, will continue to apply."
            ]
        ),
        LegalSection(
            heading: "Disclaimers",
            paragraphs: [
                "Bulletin is provided \"as is\" and \"as available\" without warranties of any kind, express or implied, including warranties of merchantability, fitness for a particular purpose, non-infringement, accuracy, or availability. We do not warrant that events are accurate, safe, lawful, or suitable for you, that the app will be uninterrupted or error-free, or that content will be preserved.",
                "Some jurisdictions do not allow the exclusion of certain warranties, so some of these exclusions may not apply to you."
            ]
        ),
        LegalSection(
            heading: "Limitation of liability",
            paragraphs: [
                "To the fullest extent permitted by law, we will not be liable for indirect, incidental, special, consequential, exemplary, or punitive damages, or for lost profits, data, goodwill, or opportunities, arising out of or relating to Bulletin, even if we have been advised of the possibility of such damages.",
                "To the fullest extent permitted by law, our total liability for all claims relating to Bulletin will not exceed the greater of the amount you paid us in the twelve months before the claim or twenty U.S. dollars. Some jurisdictions do not allow these limits, so they may not apply to you."
            ]
        ),
        LegalSection(
            heading: "Indemnification",
            paragraphs: [
                "You agree to defend, indemnify, and hold harmless \(LegalConfig.operatorName) and its officers, directors, employees, and agents from claims, damages, losses, liabilities, and expenses (including reasonable attorneys' fees) arising from your content, your events, your use of Bulletin, or your violation of these Terms or the rights of another person."
            ]
        ),
        LegalSection(
            heading: "Governing law and disputes",
            paragraphs: [
                "These Terms are governed by the laws of the \(LegalConfig.jurisdiction), without regard to conflict-of-law rules. You and we agree to resolve disputes in the state or federal courts located in Albany County, New York, and each party consents to the personal jurisdiction of those courts.",
                "Before filing a claim, please contact us so we can try to resolve the issue informally. Nothing in these Terms prevents you from bringing a claim in small claims court or exercising a right that cannot be waived under applicable law."
            ]
        ),
        LegalSection(
            heading: "Apple App Store terms",
            paragraphs: [
                "If you downloaded Bulletin from the Apple App Store, you and we acknowledge that these Terms are between you and us, not Apple. Apple is not responsible for the app or its content, has no obligation to provide maintenance or support, and is not responsible for any claims relating to the app, including product liability, legal compliance, or intellectual property claims.",
                "Apple and its subsidiaries are third-party beneficiaries of these Terms and may enforce them against you. You must comply with the App Store Terms of Service when using the app. To the extent required by Apple, Apple's standard Licensed Application End User License Agreement also applies."
            ]
        ),
        LegalSection(
            heading: "Changes to these Terms",
            paragraphs: [
                "We may update these Terms as the app changes. We will change the \"Last updated\" date and, for material changes, provide a notice in the app or by email. Continuing to use Bulletin after an update means you accept the revised Terms."
            ]
        ),
        LegalSection(
            heading: "General",
            paragraphs: [
                "These Terms and the Privacy Policy are the entire agreement between you and us about Bulletin. If any provision is found unenforceable, the rest will remain in effect. Our failure to enforce a provision is not a waiver. You may not assign these Terms without our consent; we may assign them in connection with a merger, acquisition, or sale of assets. Nothing in these Terms creates a partnership, agency, or employment relationship."
            ]
        ),
        LegalSection(
            heading: "Contact",
            paragraphs: [
                "Questions about these Terms can be sent to \(LegalConfig.supportEmail)."
            ]
        )
    ]
}
