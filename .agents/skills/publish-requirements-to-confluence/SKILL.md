---
name: publish-requirements-to-confluence
description: Structure analyzed requirements into a traceable Confluence document, preview the result, resolve the exact destination, and create or safely update a Confluence Cloud page with explicit authorization. Use when users ask to organize completed requirement analysis, convert requirements or a specification into a Confluence-ready page, or upload and publish an analyzed requirements document to Confluence.
---

# Publish Requirements to Confluence

Transform completed requirement analysis into a clear, traceable Confluence page, show the user what will be published, and protect existing content and version history during the write.

Read [references/confluence-cloud-api.md](references/confluence-cloud-api.md) before accessing Confluence or preparing an API request. Read [references/requirements-structure.md](references/requirements-structure.md) when organizing the document.

## Access Boundary

Prefer an approved Confluence connector when it can resolve and update the exact target safely. Otherwise use Confluence Cloud REST API v2 with credentials from environment variables or an approved secret store. Never print, log, persist, or place credentials in prompts, repositories, URLs, command arguments, generated documents, or responses.

Treat space and page discovery as read-only. Treat creating a page, updating content or title, adding labels, moving a page, changing restrictions, or uploading attachments as external writes. Publish only when the user has explicitly requested the exact create or update operation and the target is unambiguous.

## Preparation Flow

1. Identify the analyzed source material, intended audience, document language, and expected outcome. Preserve source links, identifiers, decisions, and ownership when provided.
2. Separate confirmed requirements, assumptions, decisions, dependencies, constraints, risks, and open questions. Do not invent missing requirements, acceptance criteria, owners, dates, or decisions; mark missing information explicitly.
3. Organize the content with the requirement structure reference. Keep stable requirement IDs when present. When IDs are absent and traceability matters, propose neutral IDs without implying that they came from the source.
4. Preserve technical details needed for implementation while consolidating duplicates and separating business intent from proposed implementation. Record material conflicts instead of silently choosing one interpretation.
5. Produce a user-visible preview or structured summary before publishing. Include the planned page title, document sections, omitted or unresolved content, and whether the action will create or update a page.

## Destination Flow

1. Resolve the exact Confluence Cloud site, numeric space ID, parent page ID when applicable, page title, and create-versus-update intent. Convert a space key to its numeric ID through a read-only lookup.
2. Search the target space for an existing current page with the same title. If more than one candidate exists or the parent differs, stop and ask the user to choose. Never infer an update target from title alone when ambiguous.
3. For an update, fetch the latest page body in storage format, parent, title, and version immediately before writing. Preserve content outside the intended replacement scope. Confluence updates send a complete latest body and can overwrite diverged drafts, so describe the replacement boundary in the preview.
4. Confirm that the authenticated account has the required space and page permissions. A valid token does not prove permission to the selected destination.
5. Obtain explicit authorization for the final target and previewed content when it has not already been provided. Reconfirm if the target, replacement boundary, or material content changed after the preview.

## Publish and Verify

1. Convert the approved document to safe Confluence storage-format markup. Escape source text, preserve links, and use supported headings, lists, tables, and code blocks. Do not inject untrusted raw HTML or unsupported macros.
2. Create with `POST /wiki/api/v2/pages`, or update with `PUT /wiki/api/v2/pages/{id}` using the latest version number plus one. Include a concise version message for updates.
3. On a conflict or version mismatch, stop, re-read the current page, show the divergence, and obtain renewed authorization before rebuilding the update. Do not overwrite blindly.
4. Read the resulting page back and verify its title, space, parent, status, version, and essential sections. Return the page ID and user-facing link without exposing unrelated private site data.
5. Report exactly what was created or updated, the source material represented, unresolved questions, and any formatting or attachment limitations.

## Stop Conditions

Stop before publishing when the destination or create/update intent is ambiguous, the source contains unresolved contradictions that materially change the page, permission or scope is insufficient, sensitive information lacks an approved destination, or preserving existing page content cannot be guaranteed.

Do not delete pages, purge drafts, change restrictions, or upload attachments under this workflow unless the user separately requests and authorizes that action.
