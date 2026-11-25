# GoLive-Bostil

**Não sabe baixar VPN nem mexer com proxy? Roda 1 arquivo e pronto.**

Ferramenta PowerShell de um comando que traz de volta o **Go Live** (transmissão de tela) do Discord
em regiões onde ele bloqueia o vídeo no SFU de voz. 

> **Escopo / ética.** Projeto de pesquisa de segurança, na **minha própria conta e nas minhas
> máquinas**. Rodar isto viola os Termos de Serviço do Discord e pode dar ação na conta. Use só em
> contas e máquinas suas, por sua conta e risco — não para burlar punição contra outros nem para
> operar um serviço.

**AMBOS OS USUÁRIOS (tanto quem inicia a live e quem assiste) DEVEM ESTAR USANDO O SCRIPT PRA FUNCIONAR!**
O patch é puramente client-sided, significa que quem não estiver rodando, ainda vai estar bloqueado regionalmente de acordo com o aplicativo padrão.
Nota: Só precisa do script o usuário que estiver bloqueado, quem não estiver bloqueado por região consegue assistir ou ser assistido normal com quem estiver com o programa.

**Só não faz bosta se for usar, tmj.**

---

## Como rodar (passo a passo)

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
uma clica no **bloco ao vivo da outra** para assistir. Se o Discord reiniciar, roda o comando de novo —
ele pula o patch do encoder (já aplicado) e reinjeta os shims.

### Parâmetros

| Parâmetro     | Padrão            | Significado                                               |
|---------------|-------------------|----------------------------------------------------------|
| `-Mode`       | `Forge`           | `Forge` / `Watch` (idênticos hoje), `Revert`, ou `Probe` |
| `-ForgeIp`    | `149.22.81.205`   | IPv4 não-brasileiro escrito em `op 1` `d.data.address`   |
| `-DebugPort`  | `9222`            | Porta de depuração remota do Discord                     |

Logs: `%LOCALAPPDATA%\GoLiveBostil\install.log`.

### Requisitos

- Windows, com Discord desktop instalado em `%LOCALAPPDATA%`.
- PowerShell. Nada para instalar na mão — o script traz o Python 3 (por usuário, silencioso) se
  faltar, só para rodar o localizador do patch binário.
- Quem transmite e quem assiste rodam (os dois lados forjam).

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

**Por que funciona, a validação, as capturas de pacote e a manutenção:** veja
[`EXPLAINER.md`](EXPLAINER.md). **Relatório formal da vulnerabilidade:** [`DISCLOSURE.md`](DISCLOSURE.md).

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
