# Learned Knowledge

Raccoglitore delle informazioni apprese durante il lavoro sul progetto.

## Regole di aggiornamento
- Ogni nuova scoperta utile va aggiunta qui.
- Ogni entry deve includere data (`YYYY-MM-DD`), contesto e impatto pratico.
- Aggiornare in modo incrementale, senza sovrascrivere la storia.

## Entries

### 2026-02-11 - Contratti operativi repository
- Contesto: analisi di `src/*/handler.py`, `tests/conftest.py`, `infra/lambda.tf`, `scripts/build_layers.ps1`.
- Apprendimento: env vars, schema DynamoDB e scheduling Lambda sono accoppiati tra codice applicativo, Terraform e fixture test.
- Impatto: ogni modifica a contract/config deve essere sincronizzata su questi tre livelli per evitare regressioni in deploy o test.

### 2026-02-11 - Build layer prima del deploy
- Contesto: analisi `infra/lambda.tf` e script layer.
- Apprendimento: Terraform referenzia `packages/dependencies-layer.zip`; il layer va generato prima di `terraform apply`.
- Impatto: nei task infrastrutturali includere sempre step di build layer per evitare errori su `aws_lambda_layer_version`.

### 2026-02-11 - Semantica retry Processor
- Contesto: analisi `src/processor/handler.py`.
- Apprendimento: il Processor usa `batchItemFailures`; alcuni fallimenti (es. transcript non disponibile/bloccato) vengono marcati FAILED senza retry, altri (LLM/salvataggio) rientrano in retry SQS.
- Impatto: fix o nuove feature nel Processor devono preservare la semantica di retry per evitare code bloccate o retry inutili.

### 2026-02-11 - AGENTS language standardization
- Contesto: richiesta di tradurre completamente `AGENTS.md` in inglese.
- Apprendimento: questo repository ora adotta AGENTS come documento operativo in lingua inglese.
- Impatto: nuove regole/processo vanno mantenute e aggiornate in inglese per coerenza operativa.

### 2026-02-19 - API keys Webshare must also set proxy type
- Contesto: debug di `scripts/manage.ps1 apikeys` e `scripts/manage.sh apikeys` dopo segnalazione che `info` mostrava proxy non configurato.
- Apprendimento: aggiornare solo `webshare_username/password` non basta; `info` e runtime dipendono da `proxy_type`.
- Impatto: quando si impostano credenziali Webshare da wizard, va scritto anche `proxy_type=webshare` per evitare stato incoerente.

### 2026-02-19 - Proxy credentials validation must not reuse API-key length checks
- Contesto: segnalazione che `manage.ps1 info` mostrava "Webshare proxy selected but credentials not set" anche con credenziali presenti.
- Apprendimento: la validazione proxy usava il controllo `api key plausible` (minimo 10 caratteri), causando falsi negativi per username/password validi ma piu corti.
- Impatto: per proxy Webshare/generic bisogna validare solo "valore configurato/non placeholder", non la lunghezza tipica delle API key.

### 2026-02-19 - Manual process monitoring must check DynamoDB status, not logs only
- Contesto: `manage.ps1 process` restava in attesa fino al timeout di 300 secondi anche quando il processor aveva gia concluso.
- Apprendimento: il monitoraggio basato solo su pattern nei log non copre alcuni esiti validi (es. `FAILED`/`PERMANENTLY_FAILED` senza log "success"), causando pending falsi.
- Impatto: per evitare timeout inutili, il monitoraggio deve usare anche lo stato DynamoDB `VIDEO#{video_id}/METADATA.status` come source of truth.

### 2026-02-19 - Process failure output should include DynamoDB reason and log excerpt
- Contesto: durante `manage.ps1 process` compariva solo `Failed: <video_id> (FAILED)` senza indicazioni utili per debug.
- Apprendimento: il motivo di failure vive nel record DynamoDB (`failure_reason`, `error`, `next_retry_at`) e i log processor filtrati per `video_id` aiutano a capire il punto esatto di rottura.
- Impatto: su failure, `process` deve stampare motivazione sintetica e alcune righe log correlate per ridurre il tempo di diagnosi.

### 2026-02-19 - PowerShell interpolation with trailing colon needs `${var}` syntax
- Contesto: errore parser in `manage.ps1` su stringa `"Processor log excerpt for $VideoId:"`.
- Apprendimento: in stringhe double-quoted, una variabile seguita subito da `:` puo essere interpretata come reference non valida; usare `${VideoId}:` evita l'ambiguita.
- Impatto: nei messaggi interpolati con suffissi `:` usare delimitazione `${...}` per evitare errori runtime.

### 2026-02-19 - Processor log debug should use filter pattern and recent fallback
- Contesto: in alcuni failure `process` mostrava reason/error da DynamoDB ma non righe log correlate al `video_id`.
- Apprendimento: query CloudWatch non filtrate su log group molto attivi possono non restituire subito eventi rilevanti; il filtro per `video_id` e un fallback "recent logs" migliorano osservabilita.
- Impatto: su failure, il comando deve prima cercare log per `video_id` e, se assenti, mostrare comunque le ultime righe processor per accelerare il troubleshooting.

### 2026-02-19 - Windows layer build must preserve `python/` prefix in ZIP
- Contesto: errore runtime Lambda `youtube-transcript-api not available` nonostante dipendenza presente nello zip layer.
- Apprendimento: `build_layers.ps1` zippava il contenuto di `layer/python` a root, ma Lambda Python layer richiede file sotto `python/`.
- Impatto: il build script PowerShell deve zippare da `layer/` e validare la presenza del prefisso `python/` per evitare layer non importabili.
