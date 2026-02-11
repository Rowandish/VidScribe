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
