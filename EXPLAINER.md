# GoLive-Bostil — como funciona e por quê

As notas de pesquisa e engenharia por trás da ferramenta. Para instalar e usar, veja
[`README.md`](README.md). Para o relatório formal da vulnerabilidade (CWE, repro de protocolo,
correção), veja [`DISCLOSURE.md`](DISCLOSURE.md).

---

## A falha, em uma frase

**O gate de região do Go Live confia num endereço que o cliente entrega, em vez do endereço que ele
mesmo vê no tráfego.**

Quando um cliente monta o transporte de voz/vídeo, ele manda uma mensagem **`op 1` (Select Protocol)**
no WebSocket do Voice Gateway. Essa mensagem leva `d.data.address`: o IP externo do próprio cliente,
descoberto pelo IP-discovery UDP do Discord. O SFU olha a **região desse endereço sinalizado** para
decidir se libera o vídeo do Go Live. Só que a mídia anda pela **5-tupla UDP observada** — o endereço
e a porta de origem reais dos pacotes que chegam no SFU — e não pelo campo sinalizado.

Então o endereço sinalizado manda no geo-gate, mas é cosmético para a entrega. Reescreva-o para um IP
de região liberada e acontece o seguinte:

- o gate abre (o `receiver_count` da transmissão vai de `0 → 1`, o encoder ativa), e
- a mídia continua fluindo pelo caminho UDP real, então o espectador recebe e decodifica o vídeo de
  verdade.

É o caso de manual de **confiança indevida em dado controlado pelo cliente** no controle de acesso. O
servidor deveria decidir pelo que observa (a 5-tupla que ele já enxerga), nunca por um valor que o
cliente escolhe.

---

## O que a validação mostrou

Os dois pontos num IP brasileiro real, sem túnel, reescrevendo só `d.data.address`:

| Forge aplicado            | IP alvo          | Resultado                                     |
|---------------------------|------------------|-----------------------------------------------|
| Só no publisher           | não-BR           | **FALHA** (encoder nunca inicia)              |
| Só no viewer              | não-BR           | **FALHA**                                     |
| Ambos, para IP **BR**     | BR               | **FALHA** (gate lê a região do sinalizado)    |
| Ambos, para IP não-BR     | `149.22.81.205`  | **PASSA** (~30 fps, 1280×704 decodificado)    |
| Ambos, para IP não-BR     | `8.8.8.8`        | **PASSA**                                     |
| Ambos, IP diferente cada  | não-BR           | **PASSA**                                     |

O que fica: os dois lados têm que forjar; qualquer IPv4 fora do Brasil serve (não precisa ser roteável
nem seu, só é lido pela região); e a região do canal de voz pode ficar como está.

### Confirmado na captura de pacotes (2026-11-23)

Reconfirmado ponta a ponta com **tcpdump** nos dois lados, cada um num IP brasileiro real (publisher
residencial BR e viewer saindo por Mullvad BR, dois IPs BR diferentes), **sem nenhum túnel não-BR**:

- **Só o viewer forja** (o publisher sinaliza o endereço BR real): o viewer recebe 2397 pacotes,
  **todos < 500 B** — áudio e RTCP, zero vídeo. O SFU simplesmente não retransmite o vídeo. É o Erro 2012.
- **Os dois forjam** (`op 1` → IP não-BR): o viewer recebe **1436 pacotes ≥ 900 B** (vídeo, até 1243 B)
  e o Discord decodifica **4826 frames a 30 fps** (450×720), sem nenhum `receiver-ready-timeout`.

Ou seja: o gate de retransmissão do SFU lê o **endereço sinalizado no `op 1`**, não o IP UDP real.
Forjar os dois lados basta, em IP BR real, sem VPN. Uma nota anterior falava de um "segundo gate"
server-side atrelado ao IP real e sugeria exigir egress fora do BR. Estava errado — veio de runs em que
o publisher não forjava.

---

## Manutenção e resistência a atualizações

Ela é feita de propósito para aguentar *algumas* atualizações do Discord, mas umas partes estão presas
à versão. Da pior para a menor:

1. **As assinaturas do patch do encoder são específicas da build.** A âncora da tabela de codec
   H264/H265 e as assinaturas de bytes do intervalo de keyframe saíram da build **1.0.9269**. O
   Discord se atualiza toda hora, e um `discord_voice.node` recompilado pode deslocar ou mudar esses
   padrões de bytes. O script agora **avisa alto** quando a build instalada é outra, e loga **ERRO** se
   o localizador não aplicar tudo, para um patch quebrado aparecer em vez de falhar calado. A cada
   atualização que quebrar, você re-deriva as assinaturas — acha a tabela de codec `H264\0H265`, os
   quatro sítios `lea` que referenciam o display-delta do H265, e as constantes de intervalo de
   keyframe `3000/100000 → 60/2000` — e adiciona os valores da build nova. Elas ficam em
   `signatures.json` (mais um padrão embutido no script), então é edição de dado; rode `-Mode Probe`
   para ver qual mudou.

2. **A injeção via CDP depende de `--remote-debugging-port` ser respeitado.** Se o Discord desligar a
   depuração remota nas builds de produção, todo o caminho de forge/play morre junto. É o maior risco
   existencial, e não tem mitigação dentro da ferramenta.

3. **O shim de forge se apoia no formato do payload do `op 1`** (`o.d.data.address`, JSON em texto puro
   no WebSocket de voz). Muda o schema do Select Protocol, move o IP-discovery, ou para de mandar o
   endereço como JSON sinalizado pelo cliente, e o shim precisa de atualização. O protocolo tem sido
   estável até aqui. Fique de olho.

4. **O Discord pode simplesmente corrigir a falha** — decidir pela 5-tupla observada em vez do campo
   sinalizado. Aí o forge para de funcionar de vez, que é todo o objetivo de divulgar.

5. **Shim de play** anda numa tag `video` genérica mais uma heurística de tamanho, então aguenta bem
   mudança de DOM e de classe. A peça de menor risco de todas.

6. **Comportamento do launcher.** O script sobe o `Discord.exe` de nível superior com a flag de
   depuração e conta que ele repasse a flag ao app Electron. Se o Discord refizer o launcher, revise
   isto.

### Endurecimento já no lugar

- ✅ **Assinaturas externalizadas:** um padrão embutido no script mais um `signatures.json` por build,
  então build nova é edição de dado, não de código. Para adicionar uma build: rode `-Mode Probe`, veja
  o que mudou, acrescente a entrada.
- ✅ **`-Mode Probe`:** verificação de saúde só-leitura — build do Discord, caminho do node, estado do
  patch, se o localizador acha os sítios (tabela por assinatura), e se a porta de depuração responde.
  Rode depois de toda atualização do Discord.
- ✅ **Instalador do Python verificado por assinatura Authenticode** (Python Software Foundation) antes
  de executar; aborta se a assinatura não bater.

Ainda na lista:

- Localizar o patch de keyframe pelos **valores das constantes** de intervalo, em vez de sequências de
  bytes fixas, para sobreviver a recompilações menores.

---

## Divulgação responsável

A descoberta por baixo disso — *o gate de região do Go Live confia num endereço fornecido pelo cliente
em vez da origem UDP observada* — é uma vulnerabilidade de controle de acesso legítima e reportável. O
lugar dela é o programa de segurança do Discord (HackerOne ou `security@discord.com`), em privado, com
um repro em nível de protocolo e a correção: derivar a geo da 5-tupla que o servidor observa, nunca do
campo do cliente. Publicar um bypass pronto e funcionando faz o contrário — espalha uma ferramenta de
evasão e mina uma divulgação de boa-fé. Mantenha a ferramenta privada; mande a descoberta ao
fornecedor. Write-up completo em [`DISCLOSURE.md`](DISCLOSURE.md).
