# Revisión de extensiones de cosmoSys

Código fijo: etiqueta `v0.1.0-preview.1` del fork fpgulias/cosmoSys_deploy.
Esta guía delimita la revisión solicitada; no cambia la etiqueta publicada.
Desarrollo promovido por Fran con asistencia de Codex, no atribuido a Txinto.

## Alcance de la revisión

- Complemento opcional `docker/local-plugins/cosmosys_exchange_api`: API REST de
  intercambio, tipos, relaciones y validaciones. Revisar permisos, transacciones,
  migraciones y posibles funcionalidades ya resueltas en cosmoSys.
- Árbol editorial: selección de rama, orden y jerarquía, exportación determinista
  Word/TXT e importación de correcciones a los fragmentos originales con revisión
  previa, versiones e identidades estables.
- Separación entre universo compartido y aplicaciones especializadas conectadas,
  tomando CGRol como referencia arquitectónica. No se propone cambiar la finalidad
  de CGRol ni tratar todo contenido creativo como una partida de rol.
- Contratos y límites entre núcleo, adaptadores REST y clientes; uso actual de
  cuenta de servicio, delegación pendiente y compatibilidad con despliegue existente.
- Los gestores son ejemplos de clientes que consumen cosmoSys, no requisitos para
  adoptar las extensiones del núcleo. IA/actas son servicios opcionales de entrada.

Fuera de esta revisión: formato APA7, necesidades personales de TFG/TFM/doctorado,
plantillas académicas y funciones particulares de producción musical o audiovisual.
Estos componentes comparten actualmente repositorio, pero no se solicita incorporarlos
a cosmoSys o CGRol como parte de la revisión.

## Por dónde empezar

1. `docs/semantic-exchange.md`: propuesta, API, validaciones y límites.
2. `docker/local-plugins/cosmosys_exchange_api`: implementación del complemento.
3. `clients/Intercambio-textos/bridge.py` y `rest_adapter.py`: formato y transporte.
4. `clients/Gestores/cosmosys_client.py`: ejemplo de cliente desacoplado.

Pruebas del intercambio: `python -m unittest discover -s clients/Intercambio-textos -v`.
Las pruebas del plugin requieren una instancia desechable, siguiendo semantic-exchange.md.
No ejecutar migraciones experimentales directamente sobre datos de uso.

La PR upstream #13 es un borrador anterior; no incluye todas las mejoras de esta
etiqueta. Se propone acordar primero el alcance y después preparar una contribución
acotada, resolviendo divergencias. No se solicita merge inmediato ni atribución a
los mantenedores. Para proponer cambios al fork, usar development/standalone-services.
