<div id="top">

<!-- HEADER -->
<div align="center">

# `❯ GoLive-Bostil`

<em>Traz de volta o Go Live do Discord em regiões onde ele bloqueia o vídeo — rodando 1 arquivo.</em>

<!-- BADGES -->
<img src="https://img.shields.io/badge/PowerShell-5391FE.svg?style=flat&logo=PowerShell&logoColor=white" alt="PowerShell">
<img src="https://img.shields.io/badge/GNU%20Bash-4EAA25.svg?style=flat&logo=GNU-Bash&logoColor=white" alt="GNU Bash">
<img src="https://img.shields.io/badge/Python-3776AB.svg?style=flat&logo=Python&logoColor=white" alt="Python">
<img src="https://img.shields.io/badge/JSON-000000.svg?style=flat&logo=JSON&logoColor=white" alt="JSON">
<br>
<img src="https://img.shields.io/badge/Plataformas-Windows%20%7C%20Linux-informational?style=flat" alt="Plataformas: Windows | Linux">
<img src="https://img.shields.io/badge/Licen%C3%A7a-sem%20garantia-lightgrey?style=flat" alt="Sem garantia">

</div>
<br>

> **Não sabe baixar VPN nem mexer com proxy? Roda 1 arquivo e pronto.**

Ferramenta de um comando — **PowerShell no Windows, bash no Linux** — que traz de volta o **Go Live**
(transmissão de tela) do Discord em regiões onde ele bloqueia o vídeo no SFU de voz. No Brasil o
bloqueio aparece como **Erro 2012** (`video-stream-receiver-ready-timeout`): o áudio e a miniatura
funcionam, só o vídeo nunca inicia. Sem VPN, sem túnel.

> **Escopo / ética.** Projeto de pesquisa de segurança, na **minha própria conta e nas minhas
> máquinas**. Rodar isto viola os Termos de Serviço do Discord e pode dar ação na conta. Use só em
> contas e máquinas suas, por sua conta e risco — não para burlar punição contra outros nem para
> operar um serviço.

**AMBOS OS USUÁRIOS (tanto quem inicia a live quanto quem assiste) DEVEM ESTAR USANDO O SCRIPT PRA
FUNCIONAR!** O patch é puramente client-sided — quem não estiver rodando continua bloqueado
regionalmente pelo aplicativo padrão.

**Só não faz bosta se for usar, tmj.**

---

## Índice

- [Visão geral](#visão-geral)
- [Estrutura do projeto](#estrutura-do-projeto)
- [Como rodar (Windows)](#como-rodar-windows)
- [Uso](#uso)
- [Linux](#linux)
- [Como funciona](#como-funciona)
- [Licença / isenção](#licença--isenção)

---

## Visão geral

O gate de região do Go Live confia num endereço que o **cliente** entrega (o `op 1` `d.data.address`
do Voice Gateway), em vez do endereço que o servidor **observa** no tráfego. Reescrevendo esse campo
para um IP fora do Brasil, o gate abre e a mídia continua fluindo pelo caminho UDP real. Esta
ferramenta faz isso em um comando: corrige o encoder, injeta o forge e o shim de play, e devolve o
controle para você.

Os dois lados (quem transmite e quem assiste) precisam rodar — um lado só deixa o gate fechado.
Os shims são de sessão (um reload do Discord apaga); o patch do encoder é em disco. Rodar de novo
pula o patch já aplicado e reinjeta os shims.

**Por que funciona, validação, capturas de pacote e manutenção:** veja [`EXPLAINER.md`](EXPLAINER.md).
**Relatório formal da vulnerabilidade:** [`DISCLOSURE.md`](DISCLOSURE.md).

---

## Estrutura do projeto

```sh
└── golive-bostil/
    ├── GoLive-Bostil.ps1   # Windows — orquestrador PowerShell (patch + forge + play shim)
    ├── GoLive-Bostil.cmd   # Windows — atalho de duplo clique que chama o .ps1
    ├── golive-bostil.sh    # Linux   — orquestrador bash (mesmos modos e fluxo)
    ├── golive_patch.py     # Linux   — patcher ELF do encoder (discord_voice.node)
    ├── signatures.json     # assinaturas do patch do encoder, por build do Discord
    ├── README.md           # este arquivo (PT-BR)
    ├── README.en.md        # versão em inglês
    ├── EXPLAINER.md         # como e por que funciona (PT-BR)
    ├── EXPLAINER.en.md      # como e por que funciona (inglês)
    └── DISCLOSURE.md        # relatório formal da vulnerabilidade (CWE, repro, correção)
```

---

## Como rodar (Windows)

> **No Linux?** O passo a passo abaixo é do Windows. Pule para a seção [Linux](#linux).

1. Baixe o repositório (**Code → Download ZIP**, ou `git clone`) e extraia a pasta.
2. **Dê dois cliques em `GoLive-Bostil.cmd`.** Ou abra o PowerShell na pasta e rode o comando lá
   embaixo. Na primeira vez ele pode instalar o Python sozinho — deixa rolar, é silencioso e não
   pergunta nada.
3. O script corrige o encoder, abre o Discord já com o forge ativo, e para. **Deixe o Discord
   aberto.**
4. No Discord, entre no **mesmo canal de voz** que a outra pessoa.
5. Clique em **Tela / Go Live**, escolha a tela ou janela, e inicie. Clique no **bloco ao vivo da
   outra pessoa** para assistir.
6. Reiniciou o Discord? Roda de novo (dois cliques no `.cmd`).

Se preferir o PowerShell em vez do `.cmd`:

```powershell
powershell -ExecutionPolicy Bypass -File .\GoLive-Bostil.ps1
```

> **Os dois lados precisam rodar** — quem transmite e quem assiste. Sem VPN, sem túnel. Para desfazer
> o patch do encoder depois, use `-Mode Revert`.

---

## Uso

Transmitir e assistir (o padrão — patch + forge + shim de play):

```powershell
powershell -ExecutionPolicy Bypass -File .\GoLive-Bostil.ps1
```

Escolher outro IP forjado (qualquer IPv4 fora do Brasil):

```powershell
powershell -ExecutionPolicy Bypass -File .\GoLive-Bostil.ps1 -ForgeIp 8.8.8.8
```

Desfazer o patch do encoder em disco (restaura o módulo original do backup, ou reconstrói a partir do
arquivo de estado):

```powershell
powershell -ExecutionPolicy Bypass -File .\GoLive-Bostil.ps1 -Mode Revert
```

Checar a saúde do patch depois de uma atualização do Discord (só leitura, não mexe em nada):

```powershell
powershell -ExecutionPolicy Bypass -File .\GoLive-Bostil.ps1 -Mode Probe
```

### Duas pessoas transmitindo uma para a outra

As duas rodam o comando padrão (mesmo `-ForgeIp` ou diferente, os dois funcionam). Depois, na mão, no
Discord: as duas entram no **mesmo canal de voz**, cada uma clica em **Tela / Go Live** e inicia, cada
uma clica no **bloco ao vivo da outra** para assistir. Se o Discord reiniciar, roda o comando de novo
— ele pula o patch do encoder (já aplicado) e reinjeta os shims.

### Parâmetros (Windows)

| Parâmetro     | Padrão            | Significado                                               |
|---------------|-------------------|----------------------------------------------------------|
| `-Mode`       | `Forge`           | `Forge` / `Watch` (idênticos hoje), `Revert`, ou `Probe` |
| `-ForgeIp`    | `149.22.81.205`   | IPv4 não-brasileiro escrito em `op 1` `d.data.address`   |
| `-DebugPort`  | `9222`            | Porta de depuração remota do Discord                     |

Logs: `%LOCALAPPDATA%\GoLiveBostil\install.log`.

### Requisitos (Windows)

- Windows, com Discord desktop instalado em `%LOCALAPPDATA%`.
- PowerShell. Nada para instalar na mão — o script traz o Python 3 (por usuário, silencioso) se
  faltar, só para rodar o localizador do patch binário.
- Quem transmite e quem assiste rodam (os dois lados forjam).

---

## Linux

A versão Linux é um script bash, `golive-bostil.sh`, com os mesmos quatro modos e o mesmo fluxo da
versão Windows (usa a porta de depuração remota do Discord via CDP e aplica o patch no mesmo
`discord_voice.node`, só que como binário ELF em vez de DLL PE).

```bash
bash golive-bostil.sh                 # Forge (padrão): patch + forge + play shim
bash golive-bostil.sh --forge-ip 8.8.8.8
bash golive-bostil.sh --mode Revert   # desfaz o patch do encoder em disco
bash golive-bostil.sh --mode Probe    # checagem de saúde só-leitura
```

### Parâmetros (Linux)

| Parâmetro       | Padrão            | Significado                                              |
|-----------------|-------------------|---------------------------------------------------------|
| `--mode`        | `Forge`           | `Forge` / `Watch` (idênticos hoje), `Revert`, `Probe`   |
| `--forge-ip`    | `149.22.81.205`   | IPv4 não-brasileiro escrito em `op 1` `d.data.address`  |
| `--debug-port`  | `9222`            | Porta de depuração remota do Discord                    |
| `--timeout`     | `45`              | Segundos de espera pelo alvo DevTools do Discord        |
| `--no-pause`    | —                 | Pula o prompt final (ou use a env `GOLIVE_NOPAUSE`)     |

Logs: `$XDG_DATA_HOME/GoLiveBostil/install.log` (ou seja, `~/.local/share/GoLiveBostil/install.log`).

### Requisitos (Linux)

- Linux com Discord desktop — nativo (deb/tar/AUR), **Flatpak** (`com.discordapp.Discord`), ou
  **Snap**. O script detecta os três sozinho (stable, PTB, Canary).
- `python3` (só a biblioteca padrão — o cliente WebSocket do CDP e o localizador do patch binário são
  inline). Diferente do Windows, ele **não** é instalado sozinho: se faltar, instale
  (`sudo apt install python3` / `sudo dnf install python3` / `sudo pacman -S python`).
- Quem transmite e quem assiste rodam (os dois lados forjam).

### Assinaturas do patch do encoder no Linux

O shim de forge e o shim de play independem de sistema operacional e funcionam como estão. Já o
**patch do encoder** depende de assinaturas de bytes tiradas de uma build específica do Windows
(`1.0.9269`). O `discord_voice.node` do Linux é um binário ELF diferente, com layout de bytes
próprio, então essas assinaturas não batem com uma build Linux. Até alguém adicionar uma entrada
Linux ao `signatures.json`, o script avisa e **pula o patch do encoder** (o gate de região ainda abre
pelo shim de forge; alguns receptores podem falhar em decodificar vídeo H265). Para adicionar uma:
rode `--mode Probe`, re-derive a âncora da tabela de codec, os sítios `lea` e as constantes de
keyframe da sua build, e acrescente a entrada em `signatures.json` — mesmo schema, mesmo arquivo para
os dois sistemas. Veja [`EXPLAINER.md`](EXPLAINER.md) para a derivação.

---

## Como funciona

Um comando, três tarefas, e então ele devolve o controle para você.

1. **Patch do encoder** (`discord_voice.node`, em disco). Força o encoder do Go Live a **H264** (H265
   trava muito receptor) com um intervalo de keyframe curto, para quem entra no meio pegar um frame
   rápido. Reversível: grava um backup `.stockbak` e um `.patch-state.json`. Roda com o Discord parado.
2. **Shim de forge** (renderer, via CDP). O Discord sobe com `--remote-debugging-port`; um script é
   injetado antes do bundle do app carregar e reescreve o `op 1` `d.data.address` do Voice Gateway
   para o IP fora do BR que você escolheu. É essa parte que abre o gate de região.
3. **Shim de play** (renderer). Força `.play()` no `<video>` remoto grande (o Discord às vezes deixa
   ele pausado, então zero frame decodifica mesmo com vídeo chegando).

Os dois shims são de sessão (um reload do Discord apaga); o patch do encoder é em disco. Rodar de novo
pula o patch quando já está aplicado (SHA bate) e reinjeta os shims.

---

## Licença / isenção

Sem garantia. Este projeto é disponibilizado **apenas para fins de pesquisa de segurança e educação**,
como parte de um processo de divulgação responsável, feito na conta e nas máquinas do próprio autor.

**Use por sua conta e risco.** Rodar esta ferramenta viola os Termos de Serviço do Discord e pode levar
à suspensão ou ao banimento da sua conta. Você é o único responsável pelo uso que faz dela e por
cumprir os Termos de Serviço do Discord e toda a legislação que se aplica a você.

O software é fornecido "como está", sem garantia de qualquer tipo. Na máxima extensão permitida por
lei, o autor não assume **nenhuma responsabilidade** por qualquer dano, perda, ação na conta ou
consequência jurídica decorrente do uso, mau uso ou distribuição deste software **por você ou por
terceiros**. Ao baixar, executar ou distribuir, você aceita estes termos e assume total
responsabilidade pelos seus próprios atos.

Este projeto não é afiliado, autorizado nem endossado pela Discord Inc.

---

🇬🇧 English version: [`README.en.md`](README.en.md).

<sub>Estrutura do README gerada com <a href="https://github.com/eli64s/readme-ai">readme-ai</a>; conteúdo escrito à mão.</sub>

<div align="right"><a href="#top">⬆ voltar ao topo</a></div>

</div>
