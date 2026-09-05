# Kontekst projektu dla Claude Code

## Co to za projekt

Ansible IaC dla warstwy sieciowej domowej sieci na MikroTiku (RouterOS), przez
API `community.routeros`. Dwa urządzenia:

- **RB5009** — router brzegowy. Mostek LAN z filtrowaniem VLAN (VLAN `main` id 1
  = `10.0.0.0/24`, VLAN `servers` id 20 = `10.0.20.0/24`), WAN po PPPoE na
  tagowanym VLAN-ie 35 (MTU 1492), serwer WireGuard (443/udp, MTU 1412,
  `10.100.0.0/24`), DHCP dla obu VLAN-ów, `/ip dns` forwardujący do
  resolwera z ad-blockingiem w VLAN-ie serwerowym z fallbackiem przez Netwatch,
  firewall z przechwyceniem DNS, blokadą DoT/DoH i segmentacją main↔servers.
- **CRS310** — switch (RouterOS, **nie SwOS-Lite**). Lustrzana tablica VLAN,
  porty access, trunk do RB5009. Adres zarządzania w VLAN-ie serwerowym.

Kontroler łączy się przez API RouterOS (`connection: local`, brak SSH do
urządzeń dla configu). Osobne repo od warstwy usług (`ansible-homelab-template`)
— inny blast radius, inna kolekcja, inny cykl życia (ADR-0001).

## Twarde zasady

- **Nigdy nie commituj realnych sekretów ani plików spoza `*.example`.**
  `.gitignore` wymusza to dla `inventory/hosts.yml`, `group_vars/**/*.yml`
  i `group_vars/**/vault.yml`. Realne IP, prawdziwe MAC-i, hasło konta,
  klucze WireGuard, dane PPPoE — wyłącznie w ignorowanych plikach lokalnych.
  Po każdym commicie `git grep` musi być pusty (wzorce w skrypcie CI-owym /
  historii commitów).
- **`api_modify` z `handle_absent_entries: remove` / `handle_entries_content:
  remove*` REALNIE usuwa niezarządzane wpisy na ścieżce.** `routeros_firewall`
  używa tego świadomie na CAŁEJ ścieżce `ip firewall filter` (przejmuje ją) —
  ręcznie dodana reguła zniknie. Dla ścieżek bez klucza głównego, na których
  rola posiada tylko część wpisów (`ip route`, `ip firewall mangle`),
  obowiązuje wzorzec z **ADR-0009**: komentarz `ansible:<cel>` + parowany task
  sprzątający, nigdy `remove` na całej ścieżce.
- **Testuj role najpierw na CHR** (`docs/bootstrap/chr-test-vm.sh`), kanonicznie
  przez `ansible-playbook -i inventory/hosts.yml site.yml --limit test`, **nie**
  przez doraźny playbook `test-<rola>.yml` (taki scratch duplikuje
  `module_defaults` i omija `pre_tasks` assert — testuje inną ścieżkę niż
  produkcja). Scratch playbook, jeśli powstał — usuń przed commitem roli i
  **nie** dodawaj do `.gitignore` (ma być widoczny w `git status`).
- Przed commitem `pre-commit run --all-files` (ansible-lint + yamllint). Jeśli
  lint coś łapie — napraw kod, nie regułę.
- Nie wyłączaj wbudowanego `admin` ani nie zawężaj API do IP kontrolera przed
  potwierdzeniem, że konto zarządzające (`routeros_api_user`) działa — oba to
  odroczone kroki za tagami `disable-admin` / `restrict-api` + `never`.
- **Przed pierwszym przebiegiem na sprzęcie:** oba vaulty muszą być zaszyfrowane
  (`ansible-vault encrypt group_vars/routers/vault.yml` i
  `group_vars/switches/vault.yml`), a `group_vars/all/vars.yml` musi zawierać
  realne wartości, nie kopię `.example` (sieć `10.0.0.0/24` i fikcyjne MAC-i =
  nietknięty szablon → przenumerowanie LAN-u i zerwane rezerwacje). Sprawdzenie:
  `ansible-vault view group_vars/routers/vault.yml` musi zapytać o hasło.
- **Do udostępniania repo na zewnątrz używać `git archive HEAD`, nigdy `tar` na
  katalogu roboczym.** `tar` zabierze gitignorowane `inventory/hosts.yml`,
  `group_vars/**/vars.yml` i odszyfrowany `vault.yml` — czyli dokładnie te
  pliki, które nigdy nie mają opuścić kontrolera.

## Pierwsze uruchomienie na sprzęcie (nie pomijać)

RB5009 i CRS310 **nie mają konsoli szeregowej** — lockout bez zabezpieczeń =
reset do zera i konfiguracja od nowa przez WinBox. `routeros_interfaces` i
`routeros_firewall` mogą uciąć ścieżkę L2/L3 do routera w trakcie przebiegu.

- **Mechanizm A — dead man's switch.** Wciągany automatycznie na początku
  `routeros_interfaces` / `routeros_firewall` gdy `routeros_enable_dead_mans_switch`
  (domyślnie `true`; `false` na CHR). Backup + `system scheduler` przywracający
  config po 10 min braku interwencji. Po przebiegu z potwierdzoną łącznością —
  rozbroić: `ansible-playbook ... --tags clear-rollback`.
- **Mechanizm B — Safe Mode.** `Ctrl+X` w terminalu / WinBox, **równolegle** do
  przebiegu Ansible. **Zweryfikowane na CHR:** Safe Mode obejmuje zmiany
  zrobione przez równoległą sesję API i cofa je przy zerwaniu sesji (ADR-0002).
- **Mechanizm C — port zarządzania poza mostkiem.** Przy pierwszym przebiegu na
  sprzęcie: port, przez który jesteś podłączony, wyłączony z
  `routeros_lan_bridge_ports` w lokalnym `vars.yml`; dodany osobnym przebiegiem
  po potwierdzeniu łączności przez adres `bridge-lan`. **CHR tego nie odtwarza**
  — patrz „Pułapki".
- Kolejność na sprzęcie: bootstrap (WinBox — konto, klucz SSH, `api`) →
  `routeros_common` → potwierdź konto przez SSH → `routeros_interfaces` bez
  portu zarządzania → potwierdź łączność przez `bridge-lan` → dodaj port
  zarządzania → `routeros_dhcp` / `routeros_dns` / `routeros_firewall`.
- **Switch po RB5009.** `routeros_interfaces` na RB5009 musi być zastosowany na
  sprzęcie (VLAN 20 routowany, reguła firewalla kontroler→switch) **zanim**
  CRS310 pod adresem zarządzania jest w ogóle osiągalny dla Ansible. Sam switch
  bootstrapuje się **kablem bezpośrednio do laptopa**, nie przez trunk (VLAN 1
  jest tagowany na trunku — fabryczny switch przez niego nieosiągalny). Patrz
  `docs/bootstrap/README.md`.

## Bramka idempotencji

Trzeci przebieg na sprzęcie (krok 9 w `docs/bootstrap/README.md`) musi być
`changed=0`, poza zadaniami, którym **wolno** zgłosić `changed` nawet wtedy:

- **`safety_snapshot.yml`** (wciągany przez `routeros_interfaces` i
  `routeros_firewall`) — task backupu ma `changed_when: true` na stałe, bo API
  nie zwraca nic użytecznego dla `/system backup save`.
- **`/ip dns` w `routeros_dns`, dopóki `alma` (ADR-0008) nie stoi pod swoim
  adresem w VLAN-ie `servers`.** Netwatch widzi
  `routeros_dns_primary_upstream` jako nieosiągalny, przełącza `servers` na
  fallback co przebieg, a kolejny przebieg przełącza z powrotem. Ustaje, gdy
  `alma` faktycznie odpowiada na tym adresie.

Każdy inny `changed` na trzecim przebiegu to realny dryf — zatrzymaj się i
znajdź go w `--diff`, zanim pójdziesz dalej.

**Reguła przerwania pracy na sprzęcie:** dwa lockouty pod rząd (dowolny
mechanizm ratunkowy — A, B lub C — musiał zadziałać dwa razy z rzędu) = stop na
dziś. Wróć do rehearsalu na CHR zamiast próbować dalej na sprzęcie. Powtórny
lockout bez zmiany podejścia znaczy, że przyczyna nie została zrozumiana, nie
że kolejna próba się uda.

## Struktura, którą warto znać

- **`site.yml` — jeden play, `hosts: routers`, `connection: local`.** Brak
  pluginu połączenia `community.routeros` — moduły `api*` działają lokalnie i
  same otwierają sesję API. Wspólne parametry (hostname / user / hasło /
  `tls: false`) raz w `module_defaults: group/community.routeros.api`.
  `tls: false` = plain API 8728 (api-ssl bez certyfikatu → handshake fail;
  LAN = granica zaufania — ADR-0002).
- **`pre_tasks` assert `ansible_limit is defined`.** Wszystkie hosty
  (`edge-router`, `crs310`, `chr-test`) są zagnieżdżone pod `routers`, więc bare
  `site.yml` trafiłby naraz w produkcję i CHR. Zawsze `--limit`:
  `edge` / `switches` / `test` (albo świadomie `routers`).
- **`routeros_device_class` bramkuje role.** `routeros_common` bez warunku na
  każdym RouterOS-ie; `routeros_interfaces` / `routeros_dhcp` / `routeros_dns` /
  `routeros_firewall` pod `when: routeros_device_class == 'edge'`;
  `routeros_switch` pod `== 'switch'`. Wartość z `group_vars/edge`/`switches`;
  na CHR ustawiana lokalnie w `group_vars/test/vars.yml` pod dany rehearsal.
  Sanity-check przed trójką CHR: `--list-tasks --limit test` musi zawierać
  testowaną rolę.
- **Kolejność ról** (`site.yml`): `routeros_common` (identity, konto, hardening
  usług) → `routeros_interfaces` (tworzy `bridge-lan`, `pppoe-out1`, `wg0`,
  `vlan-servers`, listy interfejsów, do których reszta się odwołuje) →
  `routeros_switch` → `routeros_dhcp` → `routeros_dns` → `routeros_firewall`
  **na końcu** (zależy od list interfejsów i wszystkich adresów; najgroźniejsza).
- **`routeros_interfaces` — kolejność zadań jest częścią specyfikacji.** Port
  trunku → tablica `interface bridge vlan` → interfejs L3 `vlan-servers` + adres
  → **`vlan-filtering: yes` jako OSTATNI task**. Mostek jest tworzony **bez**
  pola `vlan-filtering`. `routeros_switch` robi te same kroki w tej samej
  kolejności — jeśli obie role się rozjadą, to jest błąd.
- **Parametryzacja przez cięcie stringa w Jinja2, bez `ansible.utils.ipaddr`.**
  `routeros_servers_vlan_prefix` liczony raz z `routeros_vlans.servers.subnet`
  (`split('/')[0].split('.')[0:3] | join('.')`). Świadomy wybór — bez nowej
  zależności kolekcji.
- **QNAP to dwa hosty firewalla** (ADR-0008): natywny QTS
  (`routeros_qnap_native_ip`) i VM „alma" (`routeros_alma_ip`), każdy własny
  adres w VLAN-ie serwerowym. `routeros_servers_vlan_hosts` MUSI zawierać wpisy
  `qnap-native` i `alma` — `routeros_dhcp` to asserta.
- ADR-y: `docs/adr/` (0001–0010, wszystkie `Accepted`). Każdy opisuje decyzję
  już obowiązującą w kodzie.

## Pułapki tego repo

- **`vars.yml` vs `vars.yml.example` się rozjeżdżają** (jak w repo
  referencyjnym). Realny `group_vars/all/vars.yml` na kontrolerze nie dostaje
  zmian z `.example`. Zagnieżdżone struktury (`routeros_vlans`) nadpisuje się w
  `group_vars/test` **w całości, nie po kluczu** — domyślne
  `hash_behaviour: replace` sprawia, że `routeros_vlans.servers.gateway: "..."`
  tworzy zmienną o dosłownej nazwie z kropkami i cicho nie działa.
- **Wartości numeryczne / listowe: API zwraca inną formę niż CLI.**
  `ip dns cache-size` = `4096` (nie `4096KiB`); `interface bridge vlan`
  `tagged` / `untagged` = string łączony przecinkami (`| join(',')`), nie lista
  (`TypeError: unhashable type: 'list'`).
  Klasa: wysłana wartość musi dokładnie odpowiadać temu, co API zwraca.
- **Tylko ASCII w wartościach wysyłanych do API.** Pola trafiające na ścieżki
  RouterOS (`data:`, `comment:`, `on-event:`, `source:`, `cmd:`, `name:`
  wewnątrz `data:`) muszą być czystym ASCII — `librouteros` koduje protokół
  jako ASCII i rzuca `'ascii' codec can't encode character '—'` przy
  pierwszym polskim znaku albo półpauzie. Wywaliło się na `comment:` w
  `safety_snapshot.yml`. **Nazwy zadań Ansible (`name:`) mogą zostać po
  polsku** — nigdy nie idą na urządzenie. Audyt całego `roles/`:
  ```bash
  grep -rnP '[^\x00-\x7F]' --include='*.yml' roles/ | grep -vP ':\s*#' \
    | grep -vP '^\S+:\d+:\s*-?\s*name:'
  ```
  musi być pusty (dziś jest — 98 linii z niż-ASCII to same `name:` i komentarze).
- **Wersja RouterOS zmienia schemat API.** `hw-offload` na regule
  `fasttrack-connection`: CHR 7.19.4 **wymagało** go jawnie (inaczej `changed=1`
  co przebieg), sprzęt na 7.23.4 **odrzuca** je (`unknown parameter hw-offload`).
  Metadane kolekcji `community.routeros` tego nie modelują — pole ma
  `read_only=False` w obu wersjach, więc `handle_read_only` go nie dotyczy.
  Dlatego CHR musi chodzić na tej samej wersji co sprzęt (patrz
  `docs/bootstrap/README.md`), inaczej bramka testowa nie znaczy tego, co powinna.
- **`| default(omit)` nie łapie pustego stringa — używaj `| default(omit, true)`.**
  `default(omit)` podstawia się tylko przy **undefined**; pusty string w vaulcie
  przechodzi do API. `preshared-key` z pustą wartością wywalił wszystkie cztery
  peery WireGuard na RB5009 7.23.4 (`failure: invalid preshared key`). Drugi
  argument `true` rozszerza pominięcie na wartości falsy. `routeros_interfaces`
  używa tej formy dla `preshared-key` — przy każdym nowym opcjonalnym polu
  zaczynaj od `default(omit, true)`, nie od gołego `default(omit)`.
- **Bramka idempotencji jest ŚLEPA na dryf na ścieżkach bez klucza głównego.**
  Przy dwóch sprzecznych trasach domyślnych (ECMP przez nieistniejącą bramę)
  trzeci przebieg zgłosił `changed=0`. Dla `ip route` / `ip firewall mangle`
  potrzebny jawny check stanu na urządzeniu po zmianie zmiennej — ADR-0009.
- **`--check` NIE waliduje istnienia interfejsów.** `invalid value for argument
  interface` wychodzi dopiero przy realnym wywołaniu API. Lista portów
  niepasująca do liczby NIC-ów CHR przechodzi check-mode i wywala się na apply.
- **Mechanizm C jest nieodtwarzalny na CHR.** Przebieg z portem zarządzania w
  `routeros_lan_bridge_ports` przeszedł czysto na CHR (`ok=25 changed=24`), bo
  adres zarządzania CHR (`192.168.122.0/24`) i adres mostka (`10.0.0.0/24`) są
  w RÓŻNYCH podsieciach — RouterOS przeniósł adres na mostek (flaga `S`/SLAVE),
  L2 nie padło. Na RB5009 oba są w JEDNEJ podsieci + przeprogramowanie
  switch-chipa. Czysty przebieg na CHR **nie jest dowodem** bezpieczeństwa na
  sprzęcie.
- **Mostek w tablicy VLAN: `untagged` dla VLAN-u, którego adres siedzi wprost
  na mostku — i CHR tego NIE wykrywa.** `routeros_lan_address` jest na
  `bridge-lan` (nietagowany), więc w wierszu VLAN-u `main` `bridge-lan` musi
  być w `untagged` razem z portami dostępowymi, a w `tagged` zostaje sam trunk.
  `bridge-lan` w `tagged` dla VLAN-u 1 = po włączeniu `vlan-filtering` CPU nie
  odbiera tego VLAN-u: porty dostępowe mają link i zero łączności L3
  (potwierdzone na RB5009; przeniesienie do `untagged` naprawia natychmiast).
  Dla VLAN-u `servers` `tagged` jest poprawne — CPU dochodzi tam przez
  sub-interfejs `vlan20-servers`. Reguła: mostek idzie tam, skąd sięga się po
  adres danego VLAN-u. **CHR tego nie złapie**, bo sesja zarządzania idzie tam
  przez `ether1` poza mostkiem (`routeros_lan_bridge_ports` na teście to sam
  `ether3`) — adres mostka nigdy nie jest ścieżką zarządzania, więc przebieg
  jest czysty mimo martwego VLAN-u 1. Reguła i sankcjonowany rozjazd między
  `routeros_interfaces` a `routeros_switch` — **ADR-0010**. Ta sama klasa co
  „Mechanizm C jest nieodtwarzalny na CHR".
- **`vlan-filtering: yes` na sprzętowym switch-chipie = najczęstszy
  self-lockout.** Mostek zaczyna egzekwować tablicę VLAN w chwili włączenia —
  niekompletna tablica ucina port. CHR obowiązkowy, mechanizm C.
- **Przechwycenie `:53` przez `action=redirect`, nie `dst-nat` do resolwera.**
  `redirect` trzyma translację na routerze, conntrack un-NAT-uje odpowiedź —
  klient z zahardkodowanym zewnętrznym DNS w tej samej podsieci akceptuje
  odpowiedź. `dst-nat` do hosta wymagałby dodatkowego `srcnat` (hairpin).
- **Blokada DoH ma CELOWY wyjątek tylko dla resolwera z ad-blockingiem**
  (`doh-exempt` — używa DoH jako własnego upstreamu). Nie „upraszczać" reguły
  usuwając `src-address-list=!doh-exempt`.
- **DHCP advertuje router (bramę VLAN-u) jako DNS, nie resolwer bezpośrednio**
  (ADR-0004). Przy awarii resolwera Netwatch przełącza upstream na resolwery
  publiczne — internet działa, ale bez ad-blockingu.
- **MSS clamping na OBU interfejsach** (PPPoE 1492, WG 1412) obowiązkowy —
  brak = ciche blackholowanie TCP dla części witryn.
- **Asymetria SERVERS→LAN jest świadoma** (ADR-0006): `accept SERVERS→LAN` bez
  ograniczeń, bo QVR Pro na QNAP-ie łączy się wychodząco do kamer na VLAN main.
  Skompromitowany serwer ma pełny zasięg do main-LAN — zaakceptowane. Nie
  zawężać do RTSP/kamer bez pytania.
- **Import klucza SSH konta zarządzającego to krok bootstrap** (plikowy
  `/user/ssh-keys/import`, nie przez API) — `routeros_common` go nie wgrywa.

## Konwencje

- Nazwy tasków Ansible (`name:`) — po polsku. Komentarze w kodzie (`#`) — po
  angielsku. Commity — po angielsku, Conventional Commits (`feat:` / `fix:` /
  `docs:` / `chore:`). `README.md` + ADR-y — po angielsku. `CLAUDE.md` — po
  polsku.
- **Bez trailera `Co-Authored-By: Claude ...`** (ani żadnego AI) w commitach.
- Wartości domyślne przez zmienne w `group_vars/all/vars.yml.example`, nie
  twardo w rolach.

## Czego NIE rób bez pytania

- Nie zmieniaj kolejności ról w `site.yml` bez wyjaśnienia zależności.
- Nie zmieniaj kolejności zadań w `routeros_interfaces` / `routeros_switch`
  wokół `vlan-filtering` (patrz „Struktura").
- Nie usuwaj wpisów `.gitignore` o `vault.yml` / `hosts.yml` / `group_vars/**`.
- Nie dodawaj kolekcji ani `ansible.utils.ipaddr` bez wpisu do
  `collections/requirements.yml` (i bez powodu — cięcie stringa to wybór).
- Nie odtwarzaj configu klikaniem w WinBox/WebFig poza jednorazowym bootstrapem
  (ADR-0002).
- Nie kopiuj archiwum backupu poprzedniego routera do repo (zawiera
  nieanonimizowane sekrety).
- Nie zawężaj `accept SERVERS→LAN` (ADR-0006) bez pytania.
- CRS310: RouterOS, nie SwOS-Lite — `community.routeros` nie zadziała na SwOS.
