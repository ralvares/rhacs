# PDF summary agent demonstration

## Why this use case exists

AI application risk is not limited to chat prompts. A document can contain two different views: the pixels a person sees and the text an extraction library returns. If an application places all extracted text directly into a model request, document content can influence the model's behavior.

This use case is intentionally harmless. The demonstration document asks the model to return `HELLO`. It does not use tools, access files, send network callbacks, or expose credentials.

## Application flow

```mermaid
flowchart LR
    user[User] -->|uploads PDF| api[FastAPI]
    api --> validation[Pydantic validation]
    validation --> extraction[PyPDF extraction]
    extraction --> state[Pydantic DocumentState]
    state --> graph[LangGraph workflow]
    graph --> inference[OpenAI-compatible model API]
    inference --> ui[Browser summary]
    hidden[White text layer] --> extraction
```

The components have separate responsibilities:

- FastAPI provides the upload endpoint and browser application.
- Pydantic defines the workflow state and validates the response contract.
- PyPDF extracts text from every PDF page.
- LangGraph makes the extraction and summarization stages explicit.
- LangChain OpenAI calls the same OpenAI-compatible inference endpoint configured for the lab.
- ReportLab generates the self-contained demonstration PDF.

## Presentation flow

1. Run `make document-agent-url` and open the displayed Route.
2. Select **Download demonstration PDF**.
3. Open the PDF and show the visible community update. There is no visible instruction.
4. Upload the same PDF and select **Summarize document**.
5. Pause when the agent returns `HELLO` instead of a summary.
6. Expand **Inspect extracted text**. The audience can now see the sentence present in the PDF text layer.
7. Explain that the model did not read pixels like the user. It received the extractor's complete output as part of its prompt.

For a route-level rehearsal check:

```sh
make document-agent-test
```

The expected summary field is `HELLO`. The output also identifies the page count, extracted character count, and the four workflow stages.

## Security discussion

The lesson is the trust boundary, not this specific wording or PDF technique. Uploaded files are untrusted input. Production controls can include document provenance, content isolation, explicit instruction/data separation, least-privilege tools, output validation, human approval for consequential actions, and runtime monitoring. A model-side instruction alone is not a complete security boundary.

The workload runs as a non-root UBI container with dropped Linux capabilities and RuntimeDefault seccomp. Its model credential comes from the existing `inference-credentials` Secret. RHACS setup declares and locks the expected process and network baselines for `document-agent`, including Route ingress, DNS, and the CRC-host model connection.
