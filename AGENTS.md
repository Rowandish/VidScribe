# AGENTS.md

## Purpose
Operational guide for agents contributing to VidScribe.
Goal: make safe, verifiable changes aligned with the real behavior of the codebase.

## Real Repository Map
- Lambda application: `src/poller/handler.py`, `src/processor/handler.py`, `src/newsletter/handler.py`
- Tests: `tests/` (pytest + moto)
- Infrastructure: `infra/` (Terraform) + `infra/bootstrap/` (backend state bootstrap)
- Operational scripts: `scripts/setup.ps1|.sh`, `scripts/build_layers.ps1|.sh`
- Package artifacts: `packages/`
- Operational docs: `docs/`

## Non-Negotiable Rules
- Keep changes small, focused, and reversible.
- Update tests/documentation when behavior changes.
- Do not introduce new dependencies without explicit need.
- Every requested change must be properly committed, with an English and descriptive commit message.
- Do not change environment variable naming/contracts without updating all of the following together:
  1. Lambda code in `src/*/handler.py`
  2. Terraform in `infra/lambda.tf`
  3. Test fixtures in `tests/conftest.py`

## Standard Workflow
1. Analyze impacted files and active contracts (SQS/EventBridge events, DynamoDB schema, env vars).
2. Implement the minimum required change.
3. Run relevant local checks.
4. Update technical documentation when needed.
5. Record learnings in `docs/learned-knowledge.md`.

## Required Checks
- Python tests (project root):
  - `python -m pytest`
  - or targeted tests: `python -m pytest tests/test_processor.py -v`
- Terraform (if you touch `infra/`):
  - `terraform -chdir=infra fmt`
  - `terraform -chdir=infra validate`
- Terraform bootstrap (if you touch `infra/bootstrap/`):
  - `terraform -chdir=infra/bootstrap fmt`
  - `terraform -chdir=infra/bootstrap validate`

## Code Technical Conventions
- DynamoDB uses composite PK/SK:
  - video metadata: `pk=VIDEO#{video_id}`, `sk=METADATA`
  - queryable summary: `pk=SUMMARY#{video_id}`, `sk=DATA`, GSI `GSI1(gsi1pk, gsi1sk)`
- Processor Lambda uses SQS partial batch response (`batchItemFailures`):
  - transcript/unavailable failures are marked FAILED and usually should not be retried
  - LLM/save failures can be retried
- boto3 clients are initialized at module level in handlers:
  - in tests, import functions/modules after mocks are active when required
- Before `terraform apply`, the dependencies layer must exist at `packages/dependencies-layer.zip` (build via scripts in `scripts/`).

## Documentation-as-You-Learn Policy
- Mandatory file: `docs/learned-knowledge.md`
- Every useful new finding must be added as an entry.
- Minimum entry format:
  - Date: `YYYY-MM-DD`
  - Context
  - Learning
  - Practical impact
- Keep history append-only (do not overwrite previous entries).

## Output Quality Criteria
- Always state: what changed, why, and residual risk.
- If something could not be validated, state it explicitly.
- Avoid unrelated refactors in the same change set.
