# Where are the applications?

This is currently one fork containing multiple components, not multiple GitHub
repositories. The default main branch retains the original deployment project.
Select `development/standalone-services` to see the new development.

| Directory | Implemented scope |
|---|---|
| clients/Gestores | Local story/academic browser prototypes |
| clients/Intercambio-textos | Reversible Word/text desktop client and codec |
| clients/IA-local | Desktop dictation/actas, optional REST service connection |
| services | Separate inference, minutes and reviewed wiki-publication processes |
| docker/local-plugins/cosmosys_exchange_api | Exchange and semantic API plugin |
| clients/maintenance | Backup download helper |

Not yet implemented: APA7 specialized exporter, music-production manager,
video/series production manager, application generator, browser dictation,
SSO/LDAP integration, and full universe-version/canon modeling.
Existing academic editing is not an APA7 formatter. Existing story editing is
not an audiovisual generator. Whisper transcription is not yet exposed by the
inference service. Publication currently targets Redmine wiki pages only.

Private creative/academic content and downloaded model weights are not code and
are not published here. Splitting tools into independent repositories remains
a future packaging step; this fork is not a claim of cosmoBots endorsement.
