# Versión para revisión: v0.1.0-preview.1

26/10/2026. Desarrollo de fpgulias con asistencia de OpenAI Codex sobre el fork
de cosmoBots/cosmoSys_deploy. No es una versión oficial de cosmoBots ni se atribuyen
estas adiciones a Txinto. Se conservan historia, créditos y licencia GPL-3.0.

## Descargar una versión fija

```sh
git clone --branch v0.1.0-preview.1 https://github.com/fpgulias/cosmoSys_deploy.git
cd cosmoSys_deploy
git switch -c review/preview-1
```

La etiqueta identifica una instantánea; las nuevas correcciones irán a la rama
development/standalone-services y a etiquetas posteriores, sin mover esta etiqueta.
La PR upstream #13 sigue apuntando a otra rama anterior; esta etiqueta no la actualiza
ni solicita un merge. Revisar y resolver divergencias antes de contribuir upstream.

## Qué revisar

- `clients/Intercambio-textos`: rama jerárquica a Word/TXT y cambios de vuelta con
  identidades firmadas, revisión previa, conflictos e idempotencia.
- `clients/Gestores`: aplicaciones web de historias y académico. El almacenamiento
  local académico separa el documento del universo; las obras antiguas mantienen
  su almacenamiento original. Perfil académico de Word experimental, no APA7 completo.
- `services`: REST separados para inferencia, actas, publicación revisada y
  transcripción. Contrato `services/openapi.json`. Audio persistente y adaptadores
  faster-whisper/whisper.cpp; revisión humana antes de publicar.
- `docker/local-plugins/cosmosys_exchange_api`: intercambio y propuesta semántica
  opt-in; no activar migraciones directamente en una instalación compartida.
- `clients/maintenance`: copia y cifrado; datos y claves privados no se distribuyen.

## Pruebas reproducibles sin datos privados ni GPU

En Python 3.12, preferiblemente en un entorno virtual nuevo:

```sh
python -m pip install "sounddevice>=0.5,<0.6" "cryptography>=43,<47"
python -m unittest discover -s clients/Gestores -v
python -m unittest discover -s clients/Intercambio-textos -v
python -m unittest discover -s clients/IA-local -v
python -m unittest discover -s services -v
python -m unittest discover -s clients/maintenance -v
```

Estas pruebas no descargan pesos ni acreditan inferencia real, integración completa
o instalación limpia. Para montar una instancia desechable seguir README.md y
docs/semantic-exchange.md; para clientes, docs/client-launcher.md y services/README.md.
Configurar cuentas y archivos secretos propios fuera de Git. El repositorio no
incluye las cuentas, proyectos privados, modelos ni configuración de la instalación
de Fran. Mantener los servicios locales en loopback durante la evaluación.

## Evidencias y límites

Se probaron localmente los dos motores reales, tres obras con exportación/revisión
sin diferencias y recuperación aislada de ambas bases y servidores con HTTP 200.
Los detalles fechados están en docs/PROJECT-STATUS.md, transcription-engines.md y
recovery-validation.md. No es certificación de producción ni ensayo en otro equipo.

Pendientes: APA7 completo, LDAP/SSO, delegación de identidad (se usa cuenta de servicio),
multiusuario de producción, traducción intercambiable, navegador/móvil para dictado,
multiGPU/NVLink, historial navegable del audio y gestores musicales/audiovisuales.
La API semántica propuesta no está desplegada en la instancia de uso; no confundir
relaciones descritas en documentos con restricciones ontológicas ejecutables.

Se solicita revisión de arquitectura y ubicación de los componentes, solapamientos
con funciones existentes, permisos, modelo universo/obra, contratos REST y estrategia
de migración. Las aportaciones pueden proponerse contra development/standalone-services
del fork. No hace falta instalar la copia privada para revisar este código.
