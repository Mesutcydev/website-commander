#!/usr/bin/env python3
"""Attach What's New + promotional text to every available ASC localization.

Updates:
  1) App Store version localizations (whatsNew, promotionalText) for the
     editable iOS version (PREPARE_FOR_SUBMISSION preferred).
  2) TestFlight betaBuildLocalizations.whatsNew for the given build number,
     creating missing locales to match App Store locales.

Usage:
  python3 Scripts/set-asc-metadata-all-locales.py --build 2026071703
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

try:
    import jwt
except ImportError:
    print("PyJWT required", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parents[1]
APP_ID = os.environ.get("ASC_APP_ID", "6780267869")
BLITZ = Path.home() / ".blitz" / "asc-agent"

# ASC limits
MAX_WHATS_NEW = 4000
MAX_PROMO = 170

# Localized copy. English source of truth; other locales are full translations.
# App Store whatsNew omits the TestFlight-only "What to test" section.
WHATS_NEW: dict[str, str] = {
    "en-US": """SiteAgent 1.14 — Workspace + Connect Website Wizard

• Settings is now Workspace-first: Website, Connection Status, Assistant, and Deployment cards up front
• Advanced holds repository details, secrets, and developer tools; Appearance / Behavior stay below
• New 4-step Connect Website wizard: GitHub → pick a repo → connect hosting → choose AI
• Deployment simple mode: connect with a deploy hook (Workers) without drowning in tokens
• Detection no longer pretends hosting is “Connected”; Verify Connection only when needed
• Setup CTAs from Home, Sites, and Chat open the wizard or the right Workspace card""",
    "tr": """SiteAgent 1.14 — Çalışma Alanı + Site Bağlama Sihirbazı

• Ayarlar artık Çalışma Alanı odaklı: Website, Bağlantı Durumu, Asistan ve Dağıtım kartları önde
• Gelişmiş bölümde depo ayrıntıları, gizlilikler ve geliştirici araçları; Görünüm / Davranış altta
• Yeni 4 adımlı Site Bağlama sihirbazı: GitHub → depo seç → hosting bağla → AI seç
• Basit dağıtım modu: Workers için deploy hook ile bağlanın, token karmaşası olmadan
• Algılama artık “Bağlı” gibi görünmez; Bağlantıyı Doğrula yalnızca gerektiğinde
• Ana Sayfa, Siteler ve Sohbet kurulum düğmeleri sihirbazı veya doğru Çalışma Alanı kartını açar""",
    "de-DE": """SiteAgent 1.14 — Workspace + Website-Verbindungsassistent

• Einstellungen sind jetzt Workspace-first: Website-, Verbindungsstatus-, Assistenten- und Deployment-Karten zuerst
• Unter Erweitert: Repository-Details, Secrets und Entwicklertools; Darstellung / Verhalten darunter
• Neuer 4-Schritte-Assistent: GitHub → Repo wählen → Hosting verbinden → KI wählen
• Einfacher Deployment-Modus: Workers per Deploy-Hook verbinden, ohne Token-Überladung
• Erkennung bedeutet nicht „Verbunden“; Verbindung prüfen nur bei Bedarf
• Setup-CTAs von Home, Sites und Chat öffnen den Assistenten oder die passende Workspace-Karte""",
    "fr-FR": """SiteAgent 1.14 — Espace de travail + assistant de connexion

• Les réglages mettent l’Espace de travail en premier : cartes Site, Statut, Assistant et Déploiement
• Avancé regroupe dépôt, secrets et outils développeur ; Apparence / Comportement en dessous
• Nouvel assistant en 4 étapes : GitHub → choisir un dépôt → connecter l’hébergement → choisir l’IA
• Mode déploiement simple : connectez Workers avec un deploy hook, sans trop de jetons
• La détection n’implique pas « Connecté » ; Vérifier la connexion seulement si nécessaire
• Les CTA d’accueil, Sites et Chat ouvrent l’assistant ou la bonne carte Workspace""",
    "es-ES": """SiteAgent 1.14 — Espacio de trabajo + asistente de conexión

• Ajustes prioriza el Espacio de trabajo: tarjetas de Sitio, Estado, Asistente y Despliegue
• Avanzado guarda repo, secretos y herramientas; Apariencia / Comportamiento debajo
• Nuevo asistente de 4 pasos: GitHub → elegir repo → conectar hosting → elegir IA
• Modo de despliegue simple: conecta Workers con un deploy hook sin saturar de tokens
• La detección no implica «Conectado»; Verificar conexión solo cuando haga falta
• Los CTA de Inicio, Sitios y Chat abren el asistente o la tarjeta correcta""",
    "pt-PT": """SiteAgent 1.14 — Espaço de trabalho + assistente de ligação

• As definições priorizam o Espaço de trabalho: cartões de Site, Estado, Assistente e Implementação
• Avançado guarda repositório, segredos e ferramentas; Aspeto / Comportamento abaixo
• Novo assistente de 4 passos: GitHub → escolher repo → ligar hosting → escolher IA
• Modo de implementação simples: ligue Workers com um deploy hook sem excesso de tokens
• A deteção não significa «Ligado»; Verificar ligação só quando necessário
• Os CTA de Início, Sites e Chat abrem o assistente ou o cartão certo""",
    "nl-NL": """SiteAgent 1.14 — Workspace + website-koppelassistent

• Instellingen zetten Workspace voorop: Website-, Status-, Assistent- en Deployment-kaarten eerst
• Geavanceerd bevat repo, secrets en ontwikkelaarstools; Weergave / Gedrag daaronder
• Nieuwe 4-stappenassistent: GitHub → kies repo → koppel hosting → kies AI
• Eenvoudige deploymentmodus: koppel Workers met een deploy hook zonder token-overdaad
• Detectie betekent niet ‘Verbonden’; Controleer verbinding alleen indien nodig
• Setup-CTA’s van Home, Sites en Chat openen de wizard of de juiste Workspace-kaart""",
    "ru": """SiteAgent 1.14 — Рабочая область + мастер подключения сайта

• Настройки ориентированы на Рабочую область: карточки Сайта, Статуса, Ассистента и Деплоя
• В «Дополнительно» — репозиторий, секреты и инструменты; Оформление / Поведение ниже
• Новый мастер из 4 шагов: GitHub → выбрать репозиторий → подключить хостинг → выбрать ИИ
• Простой режим деплоя: подключите Workers через deploy hook без лишних токенов
• Обнаружение ≠ «Подключено»; «Проверить соединение» только при необходимости
• Кнопки настройки на Главной, в Сайтах и Чате открывают мастер или нужную карточку""",
    "ja": """SiteAgent 1.14 — ワークスペース + サイト接続ウィザード

• 設定がワークスペース優先に：ウェブサイト、接続状態、アシスタント、デプロイのカードを先頭に配置
• 詳細にはリポジトリ、シークレット、開発者向けツール。外観 / 動作はその下
• 新しい4ステップ接続ウィザード：GitHub → リポジトリ選択 → ホスティング接続 → AI選択
• シンプルなデプロイ：Workers はデプロイフックで接続（トークン過多なし）
• 検出だけでは「接続済み」になりません。必要時のみ接続を確認
• ホーム / サイト / チャットのセットアップ導線はウィザードまたは該当カードへ""",
    "ko": """SiteAgent 1.14 — 작업 공간 + 웹사이트 연결 마법사

• 설정이 작업 공간 우선: 웹사이트, 연결 상태, 어시스턴트, 배포 카드를 앞에 배치
• 고급에는 저장소, 비밀정보, 개발자 도구; 모양 / 동작은 아래
• 새 4단계 연결 마법사: GitHub → 저장소 선택 → 호스팅 연결 → AI 선택
• 간단한 배포 모드: Workers는 배포 훅으로 연결 (토큰 과다 없음)
• 감지만으로 ‘연결됨’이 되지 않음; 필요할 때만 연결 확인
• 홈/사이트/채팅 설정 CTA는 마법사 또는 해당 작업 공간 카드로 이동""",
    "zh-Hans": """SiteAgent 1.14 — 工作区 + 网站连接向导

• 设置以工作区为先：网站、连接状态、助手与部署卡片置顶
• “高级”包含仓库、密钥与开发者工具；外观 / 行为在下方
• 全新 4 步连接向导：GitHub → 选择仓库 → 连接托管 → 选择 AI
• 精简部署模式：Workers 用部署钩子连接，避免令牌堆砌
• 检测不等于“已连接”；仅在需要时验证连接
• 主页、站点与聊天中的设置入口会打开向导或对应工作区卡片""",
    "ar-SA": """SiteAgent 1.14 — مساحة العمل + معالج ربط الموقع

• الإعدادات تضع مساحة العمل أولاً: بطاقات الموقع وحالة الاتصال والمساعد والنشر
• المتقدم يحوي المستودع والأسرار وأدوات المطوّر؛ المظهر / السلوك بالأسفل
• معالج ربط من 4 خطوات: GitHub ← اختيار مستودع ← ربط الاستضافة ← اختيار الذكاء الاصطناعي
• وضع نشر مبسّط: اربط Workers بخطاف النشر دون إغراق بالرموز
• الاكتشاف لا يعني «متصل»؛ تحقق من الاتصال عند الحاجة فقط
• أزرار الإعداد من الرئيسية والمواقع والدردشة تفتح المعالج أو البطاقة الصحيحة""",
    "ro": """SiteAgent 1.14 — Spațiu de lucru + asistent de conectare

• Setările prioritizează Spațiul de lucru: carduri Site, Stare, Asistent și Implementare
• Avansat conține depozit, secrete și unelte; Aspect / Comportament dedesubt
• Asistent nou în 4 pași: GitHub → alege repo → conectează hosting → alege AI
• Mod implementare simplu: conectează Workers cu un deploy hook, fără prea multe tokenuri
• Detectarea nu înseamnă „Conectat”; Verifică conexiunea doar când e nevoie
• CTA-urile din Acasă, Site-uri și Chat deschid asistentul sau cardul potrivit""",
}

PROMO: dict[str, str] = {
    "en-US": "Chat with your website. SiteAgent edits, previews, and deploys approved changes — now with Workspace setup and a Connect Website wizard.",
    "tr": "Web sitenizle sohbet edin. SiteAgent onaylı değişiklikleri düzenler, önizler ve yayınlar — yeni Çalışma Alanı kurulumu ve Site Bağlama sihirbazı ile.",
    "de-DE": "Chatten Sie mit Ihrer Website. SiteAgent bearbeitet, zeigt Vorschauen und deployed freigegebene Änderungen — jetzt mit Workspace und Verbindungsassistent.",
    "fr-FR": "Discutez avec votre site. SiteAgent modifie, prévisualise et déploie les changements approuvés — avec Espace de travail et assistant de connexion.",
    "es-ES": "Habla con tu web. SiteAgent edita, previsualiza y despliega cambios aprobados — ahora con Espacio de trabajo y asistente de conexión.",
    "pt-PT": "Converse com o seu site. O SiteAgent edita, pré-visualiza e implementa alterações aprovadas — com Espaço de trabalho e assistente de ligação.",
    "nl-NL": "Chat met je website. SiteAgent bewerkt, toont voorbeelden en deployt goedgekeurde wijzigingen — nu met Workspace en koppelassistent.",
    "ru": "Общайтесь с сайтом. SiteAgent правит, показывает превью и деплоит одобренные изменения — с рабочей областью и мастером подключения.",
    "ja": "ウェブサイトとチャット。SiteAgent が承認済みの変更を編集・プレビュー・デプロイ。新しいワークスペース設定と接続ウィザード対応。",
    "ko": "웹사이트와 대화하세요. SiteAgent가 승인된 변경을 편집·미리보기·배포합니다. 작업 공간 설정과 연결 마법사 포함.",
    "zh-Hans": "与网站对话。SiteAgent 编辑、预览并部署已批准的更改——现支持工作区设置与连接向导。",
    "ar-SA": "تحدث مع موقعك. يعدّل SiteAgent التغييرات المعتمدة ويعاينها وينشرها — مع مساحة العمل ومعالج الربط.",
    "ro": "Vorbește cu site-ul tău. SiteAgent editează, previzualizează și implementează schimbările aprobate — cu Spațiu de lucru și asistent de conectare.",
}

TF_EXTRA = {
    "en-US": "\n\nWhat to test: open the gear → confirm Workspace cards (no owner/repo/token on the default surface); Connect Website from an empty state and finish or skip deployment; verify Chat/Home setup deep-links; confirm existing sites still work with saved credentials.",
    "tr": "\n\nTest edin: dişli simgesini açın → Çalışma Alanı kartlarını doğrulayın; boş durumdan Site Bağla’yı tamamlayın veya dağıtımı atlayın; Sohbet/Ana Sayfa derin bağlantılarını kontrol edin; mevcut sitelerin kimlik bilgileriyle çalıştığını doğrulayın.",
    "de-DE": "\n\nZum Testen: Zahnrad öffnen → Workspace-Karten prüfen; Website verbinden und Deployment ggf. überspringen; Chat/Home-Deep-Links prüfen; bestehende Sites mit gespeicherten Zugangsdaten testen.",
    "fr-FR": "\n\nÀ tester : ouvrir les réglages → vérifier les cartes Espace de travail ; Connecter un site et terminer ou ignorer le déploiement ; vérifier les liens Chat/Accueil ; confirmer que les sites existants fonctionnent.",
    "es-ES": "\n\nQué probar: abrir el engranaje → comprobar las tarjetas; Conectar sitio y terminar o omitir el despliegue; verificar deep-links de Chat/Inicio; confirmar que los sitios existentes siguen funcionando.",
    "pt-PT": "\n\nO que testar: abra as definições → confirme os cartões; ligue um site e termine ou ignore a implementação; verifique deep-links Chat/Início; confirme que os sites existentes continuam a funcionar.",
    "nl-NL": "\n\nTe testen: open het tandwiel → controleer Workspace-kaarten; verbind een site en rond af of sla deployment over; check Chat/Home-deeplinks; bevestig dat bestaande sites nog werken.",
    "ru": "\n\nЧто проверить: откройте шестерёнку → карточки рабочей области; подключите сайт и завершите или пропустите деплой; проверьте deep-link из Чата/Главной; убедитесь, что существующие сайты работают.",
    "ja": "\n\n確認してほしいこと：歯車を開いてワークスペースカードを確認；空の状態からサイト接続を完了またはデプロイをスキップ；チャット/ホームのディープリンク；既存サイトが資格情報のまま動作すること。",
    "ko": "\n\n테스트: 톱니바퀴 → 작업 공간 카드 확인; 빈 상태에서 웹사이트 연결 후 완료 또는 배포 건너뛰기; 채팅/홈 딥링크; 기존 사이트가 저장된 자격 증명으로 동작하는지 확인.",
    "zh-Hans": "\n\n请测试：打开齿轮 → 确认工作区卡片；从空状态连接网站并完成或跳过部署；验证聊天/主页深链；确认现有站点凭据仍可用。",
    "ar-SA": "\n\nللاختبار: افتح الترس ← بطاقات مساحة العمل؛ اربط موقعاً وأكمل أو تخطَّ النشر؛ تحقق من روابط الدردشة/الرئيسية؛ تأكد أن المواقع الحالية تعمل ببيانات الاعتماد المحفوظة.",
    "ro": "\n\nDe testat: deschide roata dințată → cardurile Spațiului de lucru; conectează un site și termină sau sare peste implementare; verifică deep-link-urile Chat/Acasă; confirmă că site-urile existente încă funcționează.",
}


def load_token() -> str:
    cfg_path = BLITZ / "config.json"
    cfg = json.loads(cfg_path.read_text()) if cfg_path.exists() else {}
    key_id = os.environ.get("ASC_KEY_ID") or cfg.get("key_id") or "B7AYY3B2FT"
    issuer = os.environ.get("ASC_ISSUER_ID") or cfg.get("issuer_id") or "5ddc2a8a-c374-4f06-b9bd-916f198652be"
    key_path = Path(os.environ.get("KEY_PATH") or (BLITZ / "AuthKey_BlitzKey.p8"))
    if not key_path.exists():
        key_path = Path.home() / f"Downloads/AuthKey_{key_id}.p8"
    now = int(time.time())
    token = jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        key_path.read_text(),
        algorithm="ES256",
        headers={"kid": key_id},
    )
    return token.decode() if isinstance(token, bytes) else token


def api(method: str, url: str, token: str, body: dict | None = None) -> dict:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        err = e.read().decode()
        raise RuntimeError(f"{method} {url} → {e.code}\n{err}") from e


def clip(text: str, limit: int) -> str:
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[: limit - 3].rstrip() + "..."


def pick_version(token: str) -> tuple[str, str, str]:
    data = api(
        "GET",
        f"https://api.appstoreconnect.apple.com/v1/apps/{APP_ID}/appStoreVersions"
        f"?filter[platform]=IOS&limit=20",
        token,
    )
    prefer = [
        "PREPARE_FOR_SUBMISSION",
        "DEVELOPER_REJECTED",
        "REJECTED",
        "METADATA_REJECTED",
        "WAITING_FOR_REVIEW",
        "IN_REVIEW",
    ]
    versions = data.get("data") or []
    for state in prefer:
        for v in versions:
            if v["attributes"].get("appStoreState") == state:
                a = v["attributes"]
                return v["id"], a.get("versionString") or "", a.get("appStoreState") or ""
    if not versions:
        raise RuntimeError("No iOS App Store versions found")
    v = versions[0]
    a = v["attributes"]
    return v["id"], a.get("versionString") or "", a.get("appStoreState") or ""


def ensure_version_string(token: str, version_id: str, current: str, desired: str) -> str:
    if current == desired:
        return current
    print(f"==> Updating App Store versionString {current} → {desired}")
    api(
        "PATCH",
        f"https://api.appstoreconnect.apple.com/v1/appStoreVersions/{version_id}",
        token,
        {"data": {"type": "appStoreVersions", "id": version_id, "attributes": {"versionString": desired}}},
    )
    return desired


def update_app_store_localizations(token: str, version_id: str) -> None:
    locs = api(
        "GET",
        f"https://api.appstoreconnect.apple.com/v1/appStoreVersions/{version_id}"
        f"/appStoreVersionLocalizations?limit=200",
        token,
    )
    items = locs.get("data") or []
    print(f"==> App Store localizations: {len(items)}")
    for item in items:
        loc_id = item["id"]
        locale = item["attributes"].get("locale") or "en-US"
        whats = clip(WHATS_NEW.get(locale) or WHATS_NEW["en-US"], MAX_WHATS_NEW)
        promo = clip(PROMO.get(locale) or PROMO["en-US"], MAX_PROMO)
        print(f"  PATCH {locale} whatsNew={len(whats)} promo={len(promo)}")
        api(
            "PATCH",
            f"https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/{loc_id}",
            token,
            {
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "id": loc_id,
                    "attributes": {"whatsNew": whats, "promotionalText": promo},
                }
            },
        )


def find_build_id(token: str, build_number: str) -> str:
    data = api(
        "GET",
        f"https://api.appstoreconnect.apple.com/v1/builds?filter[app]={APP_ID}"
        f"&filter[version]={build_number}&sort=-uploadedDate&limit=5",
        token,
    )
    items = data.get("data") or []
    if not items:
        raise RuntimeError(f"Build {build_number} not found on ASC")
    return items[0]["id"]


def update_testflight_localizations(token: str, build_id: str, locales: list[str]) -> None:
    existing = api(
        "GET",
        f"https://api.appstoreconnect.apple.com/v1/builds/{build_id}/betaBuildLocalizations?limit=200",
        token,
    )
    by_locale = {
        (i["attributes"].get("locale") or ""): i
        for i in (existing.get("data") or [])
    }
    print(f"==> TestFlight build localizations (have {len(by_locale)}, want {len(locales)})")
    for locale in locales:
        body_text = clip(
            (WHATS_NEW.get(locale) or WHATS_NEW["en-US"]) + (TF_EXTRA.get(locale) or TF_EXTRA["en-US"]),
            MAX_WHATS_NEW,
        )
        if locale in by_locale:
            loc_id = by_locale[locale]["id"]
            print(f"  PATCH TF {locale}")
            api(
                "PATCH",
                f"https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations/{loc_id}",
                token,
                {
                    "data": {
                        "type": "betaBuildLocalizations",
                        "id": loc_id,
                        "attributes": {"whatsNew": body_text},
                    }
                },
            )
        else:
            print(f"  POST TF {locale}")
            api(
                "POST",
                "https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations",
                token,
                {
                    "data": {
                        "type": "betaBuildLocalizations",
                        "attributes": {"locale": locale, "whatsNew": body_text},
                        "relationships": {
                            "build": {"data": {"type": "builds", "id": build_id}}
                        },
                    }
                },
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", default="2026071703", help="CFBundleVersion / build number")
    parser.add_argument("--version", default="1.14", help="App Store marketing version string")
    parser.add_argument("--skip-version-bump", action="store_true")
    args = parser.parse_args()

    # Prefer Documentation files for en-US when present.
    wn_path = ROOT / "Documentation" / "WhatsNew.txt"
    promo_path = ROOT / "Documentation" / "PromotionalText.txt"
    if wn_path.exists():
        en = wn_path.read_text(encoding="utf-8").strip()
        # Split off TestFlight-only section for App Store.
        marker = "\nWhat to test:"
        if marker in en:
            en_store, en_tf = en.split(marker, 1)
            WHATS_NEW["en-US"] = en_store.strip()
            TF_EXTRA["en-US"] = "\n\nWhat to test:" + en_tf
        else:
            WHATS_NEW["en-US"] = en
    if promo_path.exists():
        PROMO["en-US"] = clip(promo_path.read_text(encoding="utf-8"), MAX_PROMO)

    # Never publish stale translated copy from an older release. Until each
    # locale has a translation for the current release, use the current English
    # source of truth on every existing ASC page so features/build notes agree.
    for locale in list(WHATS_NEW):
        WHATS_NEW[locale] = WHATS_NEW["en-US"]
        PROMO[locale] = PROMO["en-US"]
        TF_EXTRA[locale] = TF_EXTRA["en-US"]

    token = load_token()
    version_id, version_string, state = pick_version(token)
    print(f"==> Editable version: {version_string} ({state}) id={version_id}")
    if not args.skip_version_bump and state == "PREPARE_FOR_SUBMISSION":
        version_string = ensure_version_string(token, version_id, version_string, args.version)

    update_app_store_localizations(token, version_id)

    locs = api(
        "GET",
        f"https://api.appstoreconnect.apple.com/v1/appStoreVersions/{version_id}"
        f"/appStoreVersionLocalizations?limit=200",
        token,
    )
    locales = sorted({(i["attributes"].get("locale") or "en-US") for i in (locs.get("data") or [])})

    build_id = find_build_id(token, args.build)
    print(f"==> TestFlight build {args.build} id={build_id}")
    update_testflight_localizations(token, build_id, locales)

    print("\nDone.")
    print(f"App Store version: {version_string}")
    print(f"Locales updated: {', '.join(locales)}")
    print(f"TestFlight: https://appstoreconnect.apple.com/apps/{APP_ID}/testflight/ios")
    print(f"App Store: https://appstoreconnect.apple.com/apps/{APP_ID}/appstore")
    return 0


if __name__ == "__main__":
    sys.exit(main())
