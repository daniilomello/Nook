# Fork do Nook — Plano

Navegador pessoal em cima do [Nook](https://github.com/nook-browser/Nook) (GPL-3.0, Swift + WebKit). Uso pessoal: não vai para loja. Mac e iPhone.

- Fork: `daniilomello/Nook` (público, como todo fork de repo público). `origin` é o fork, `upstream` é o Nook original.
- Clone: `/Users/danilo/www/nook`, branch `develop` (a padrão do upstream).

## 1. O que eu quero

| # | Requisito | Situação no Nook hoje |
|---|---|---|
| 1 | Visual tipo Arc | Pronto: sidebar, spaces, pastas, favoritos, split, peek, command palette |
| 2 | Ad-block por padrão | Pronto: `NookBlocker` (adblock-rust) liga sozinho no primeiro uso, no Mac e no iOS. 10 listas ativas (EasyList, EasyPrivacy, uBlock, malware) |
| 3 | Bloqueio de redes sociais por padrão | Não existe. Só há a lista opcional "Fanboy's Social", que esconde botões de compartilhar, não bloqueia os sites |
| 4 | Bloqueio de sites pornográficos, Mac e iPhone | Não existe |
| 5 | Versão para iPhone | Existe o alvo `NookiOS` (1.500 linhas, usa os mesmos pacotes e o mesmo ad-block), nunca lançado. Falta testar em aparelho |
| 6 | Trazer cookies e histórico do Chrome | Não existe. O Nook importa de Arc, Dia e Safari. As peças de destino existem: `historyManager.importVisits` e o `httpCookieStore` de cada perfil |
| 7 | 1Password | O Nook instala extensões da Chrome Web Store e já lê a lista de extensões de um perfil Chromium. O 1Password está instalado no Chrome (perfis Default e Profile 3) |

## 2. Fases

### Fase 0 — Identidade do fork (antes de qualquer dado)
Os dados do app ficam em `~/Library/Application Support/<bundle id>/`. Trocar o bundle id depois da migração deixaria tudo para trás, então isto vem primeiro.

- Bundle id próprio e fixo (`com.danilodemellow.browser`), independente do nome que o app tiver. O nome e o ícone podem mudar depois sem mover dados.
- Desligar a atualização automática (Sparkle aponta para o appcast do upstream; uma atualização trocaria o fork pelo Nook original).
- Assinatura no Mac com o certificado "Apple Development" que já está no chaveiro e os entitlements reduzidos (`Nook-CI.entitlements`). Assinatura estável evita o macOS pedir câmera, microfone e chaveiro de novo a cada build. Push e AutoFill do sistema ficam de fora: exigem conta paga.
- `scripts/build.sh --install` no padrão dos outros apps: compila, assina, instala em `/Applications`.
- Requisito de máquina: componente Metal Toolchain do Xcode (`xcodebuild -downloadComponent MetalToolchain`).

### Fase 1 — Migração do Chrome
Um importador "Chrome" ao lado de Arc/Dia/Safari, com escolha do perfil (há 4 no Chrome: Default, Profile 1, 2 e 3).

- **Histórico:** copia o arquivo `History` do perfil (o Chrome mantém o original travado enquanto está aberto), lê as tabelas `urls` e `visits`, converte as datas e entrega para `historyManager.importVisits`.
- **Cookies:** copia o arquivo `Cookies`, decifra os valores com a chave "Chrome Safe Storage" do Chaveiro e grava no `httpCookieStore` do perfil do Nook. O macOS mostra um pedido de acesso ao Chaveiro na hora, que só você aprova.
- **Extensões e 1Password:** reaproveita `parseChromiumExtensionIDs` + `installFromWebStore`, com uma tela para escolher quais das extensões do Chrome instalar (são 28 no perfil Default; nem todas funcionam no WebKit).
- **Favoritos:** o arquivo `Bookmarks` do Chrome é JSON; entra como pastas fixadas, como já é feito com o Safari.

Limites conhecidos:
- Sessões presas ao aparelho não migram. O Google é o caso principal: o login vai ser pedido de novo. A maioria dos outros sites deve continuar logada, mas alguns derrubam a sessão quando o navegador muda.
- Senhas salvas no Chrome não entram no plano; o 1Password cobre isso.
- 1Password: a extensão deve funcionar sozinha (desbloqueio com a senha da conta). A integração com o app de desktop (Touch ID, desbloqueio compartilhado) provavelmente não funciona, porque o 1Password só aceita navegadores com assinatura conhecida. A confirmar no uso.

### Fase 2 — Bloqueio de sites (redes sociais e pornografia)
Um recurso só, com categorias, no pacote compartilhado `NookWeb`: vale para Mac e iPhone sem código duplicado.

- Ponto de corte: `PageSession+Navigation.swift`, no `decidePolicyFor` do quadro principal. Domínio bloqueado cancela a navegação e mostra uma página "bloqueado" do próprio navegador.
- **Redes sociais:** lista curta e editável, ligada por padrão (facebook, instagram, x/twitter, tiktok, threads, reddit, linkedin, youtube shorts — a lista exata é decisão sua).
- **Pornografia:** lista pública grande (dezenas de milhares de domínios), embutida no app e atualizada junto com as listas do ad-block. Fica em um conjunto em memória, não em regras do WebKit, que têm limite de tamanho.
- Busca segura forçada no Google, Bing, DuckDuckGo e YouTube, para o conteúdo não aparecer nos resultados e miniaturas.
- Também bloqueia os mesmos domínios como sub-recurso (iframes, imagens) via regra de conteúdo, para embeds.
- Ajustes: liga/desliga por categoria, lista própria de domínios, exceções.

Limite: o bloqueio vale dentro deste navegador. No iPhone o Safari continua existindo; para fechar essa porta, o caminho é o Tempo de Uso do iOS (restrição de conteúdo adulto) ou um DNS com filtro. Entra como passo opcional na Fase 3.

### Fase 3 — iPhone
Mesmo esquema do Take Mobile: Apple ID gratuito, perfil de 7 dias, renovação automática.

- Trocar bundle id e time do alvo `NookiOS` (o projeto traz os times do upstream).
- `scripts/ios-install.sh` e `scripts/ios-renew.sh` adaptados do Take (`--install-agent` renova 3 dias antes de vencer, checando a cada 4 h).
- Conferir no aparelho: ad-block, bloqueio de sites, abas, spaces, downloads.
- Levar os ajustes de bloqueio do Mac para o iPhone (os dois já usam `NookSettings`).

Limites da conta gratuita:
- Não dá para definir como navegador padrão no iPhone: isso exige um entitlement que a Apple só libera para conta paga e mediante pedido. Links de outros apps continuam abrindo no Safari.
- Sem iCloud: a sincronização Mac ↔ iPhone que o upstream está fazendo (`feature/icloud-sync`) não funciona. Alternativa futura: sincronizar pela rede local, como o Take faz.
- O alvo pede iOS 26 e o entitlement de memória ampliada; pode ser preciso remover esse entitlement no time gratuito.
- Até 3 apps de conta gratuita instalados por aparelho (o Take Mobile ocupa uma vaga).

### Fase 4 — Acabamento
- Nome e ícone próprios.
- Rotina para puxar novidades do upstream (`git fetch upstream && git merge upstream/develop`), mantendo as mudanças do fork em arquivos novos sempre que possível para reduzir conflito.
- Revisar o que vem ligado e não interessa (chat de IA, servidor MCP de desenvolvimento, tweaks de sites).

## 3. Ordem e dependências

```
Fase 0 ──► Fase 1 (Chrome) ──► uso diário no Mac
   └─────► Fase 2 (bloqueios) ──► Fase 3 (iPhone) ──► Fase 4
```

Fases 1 e 2 são independentes entre si. A Fase 3 depende da 2 para o iPhone já nascer com os bloqueios.

## 4. Decisões em aberto
- Nome do navegador (não trava nada: o bundle id é independente do nome).
- Qual perfil do Chrome migrar primeiro.
- Lista exata de redes sociais bloqueadas, e se o YouTube entra inteiro ou só os Shorts.
- Se o bloqueio pode ser desligado nos ajustes com um clique ou se deve ter algum atrito (espera, senha).
