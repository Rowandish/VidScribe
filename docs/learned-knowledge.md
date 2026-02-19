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
