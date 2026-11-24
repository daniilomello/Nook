# Fork do Nook — Tarefas

Legenda: `[x]` feito e verificado · `[~]` feito, falta testar no app · `[ ]` pendente · `[!]` limite conhecido

## Fase 0 — Identidade do fork
- [x] 0.1 Fork `daniilomello/Nook`, clone em `/Users/danilo/www/nook`, remoto `upstream`
- [x] 0.2 Bundle id `com.danilodemellow.browser` (Mac e iOS)
- [x] 0.3 Sparkle sem checagem automática e sem o appcast do upstream
- [x] 0.4 `scripts/build.sh [--install|--run]`: compila, assina com o certificado Apple Development (time `FBJ6MZQDW7`), instala em `/Applications/Nook.app`
- [x] 0.5 `scripts/sync-upstream.sh [--check]`
- [x] 0.6 Metal Toolchain do Xcode instalado
- [x] 0.7 App instalado abre sem travar e mostra o onboarding

## Fase 1 — Migração do Chrome
- [x] 1.1 Leitura do Chrome: perfis, histórico, cookies, favoritos, nomes de extensões (`ChromeImportCheck`, mais contagens conferidas contra cópias reais do `History`)
- [~] 1.2 Diálogo "Import from Chrome…" (menu, ao lado de "Import from another Browser") e botão Chrome no onboarding
- [~] 1.3 Cookies: pedido de acesso ao Chaveiro ("Chrome Safe Storage") e gravação no space atual
- [~] 1.4 Histórico dos últimos 100 dias (o Nook não guarda mais que isso)
- [~] 1.5 Extensões: lista com o 1Password pré-marcado, instalação pela Chrome Web Store
- [~] 1.6 Favoritos (desligado por padrão): uma pasta fixada "Chrome Bookmarks"
- [ ] 1.7 Rodar a importação de verdade, uma vez por perfil do Chrome que interessar
- [!] Google pede login de novo (sessão presa ao aparelho); cookies particionados (CHIPS) não migram
- [!] 1Password: integração com o app de desktop (Touch ID) provavelmente não funciona

## Fase 2 — Bloqueio de sites
- [x] 2.1 Regras e casamento de domínio/caminho, exceções, domínios próprios (51 testes em `Packages/NookBlocker/Tests`)
- [x] 2.2 Lista de conteúdo adulto: OISD NSFW + HaGeZi NSFW, 517.319 domínios, embutida (4 MB), atualização a cada 3 dias
- [x] 2.3 Redes sociais ligadas por padrão: Facebook, Instagram, X/Twitter, TikTok, Threads, Reddit, Snapchat, Pinterest, Tumblr, YouTube Shorts. Desligadas: LinkedIn e YouTube inteiro
- [x] 2.4 Busca segura forçada: Google, Bing, DuckDuckGo, Brave, Yahoo
- [x] 2.5 iOS (simulador): página de bloqueio para rede social, site adulto e Shorts; redirecionamento; iframe; `pushState`; busca filtrada
- [~] 2.6 Mac: página de bloqueio, aba "Site Blocking" nos ajustes, Peek, split, janelas de extensão
- [~] 2.7 Shorts no youtube.com de verdade (testado só em página local) e a prateleira de Shorts escondida
- [~] 2.8 Toques no iOS: Go Back, Close Tab, chaves dos ajustes, adicionar domínio, Update Now
- [x] 2.9 Bloqueio pelo nome do endereço (`AdultHostName`): "porn", "xxx", "hentai", TLDs `.xxx`/`.porn`/`.sex`/`.adult` etc. Nos 300 mil domínios mais visitados pegou 453 sites adultos que as listas não tinham
- [~] 2.10 Checagem no DNS família da Cloudflare, ligada por padrão (envia o nome de cada site aberto; desliga em Site Blocking). Regras testadas e consulta ao serviço real conferida (cerca de 20 ms por site); a derrubada da página no app não foi exercitada por mim
- [!] Nenhuma lista cobre todos os sites: um domínio novo, com nome neutro e fora das listas, só é pego pela checagem da Cloudflare
- [!] Imagens e scripts de domínios bloqueados ainda carregam dentro de outras páginas; só a navegação é bloqueada
- [!] "Entrar com Facebook/X" quebra enquanto esses sites estão bloqueados
- [!] Modo restrito do YouTube não é forçado (o WebKit não deixa)

## Fase 3 — iPhone
- [x] 3.1 `scripts/ios-install.sh` e `scripts/ios-renew.sh` (adaptados do Take)
- [x] 3.2 Build de simulador roda, ad-block ativo (46 recursos bloqueados em duas páginas de teste)
- [x] 3.3 Instalado no iPhone 15 (iOS 26.6.2) com o time pessoal; o entitlement de memória foi aceito
- [x] 3.4 Renovação automática ligada (`ios-renew.sh --install-agent`)
- [!] Não dá para definir como navegador padrão nem usar iCloud (conta gratuita)
- [!] Build pelo Xcode (GUI) falha na assinatura dos bundles de recursos; use o script

## Fase 4 — Acabamento
- [ ] 4.1 Nome e ícone próprios
- [ ] 4.2 Decidir se desligar o bloqueio deve ter atrito (espera, senha)
- [ ] 4.3 Revisar o que vem ligado e não interessa (chat de IA, servidor MCP de desenvolvimento)
- [ ] 4.4 Sincronizar ajustes de bloqueio entre Mac e iPhone (hoje cada um tem os seus)
- [~] 4.6 Ícone de teclado na barra inferior da sidebar com a lista de atalhos (o ícone aparece; o painel não foi aberto no app)
- [ ] 4.5 Investigar um `HTTP 404` do `FilterListManager` no primeiro uso (as 10 listas padrão respondem 200)
