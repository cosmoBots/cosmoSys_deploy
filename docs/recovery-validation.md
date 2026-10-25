# Copia privada y ensayo de recuperación

25/10/2026: se creó una copia lógica local de cosmoSys, CGRol y clientes. Incluye
dumps PostgreSQL, adjuntos, configuración de despliegue, plugin montado, las tres
imágenes Docker en uso, Git bundle, SQLite de gestores, archivo de audio,
documentos y configuración privada. El paquete contiene secretos y no pertenece a Git.

Se conserva la clave de firma Word. La clave SSH dedicada a backup no fue legible;
se debe regenerar para reactivar esa tarea en una recuperación. La copia no incluye
el disco completo de la VM, pesos de modelos IA, venv, runtime Python ni ejecutables
IA externos; estos requieren reinstalación. No existe una instantánea atómica entre
todos los servicios: evitar ediciones durante una copia coordinada.

Verificaciones realizadas:

- Git bundle válido e inventario SHA-256 de archivos.
- Restauración de ambas bases en PostgreSQL 16 desechable sin red publicada,
  mediante pg_restore con salida inmediata ante error.
- Arranque de ambas aplicaciones con sus bases y adjuntos restaurados en una red
  Docker interna sin puertos publicados; pantalla de acceso HTTP 200 en ambas.
  Los contenedores de prueba y la red fueron retirados al finalizar. No se ha
  recorrido toda la interfaz ni reinstalado IA desde cero.
- Lectura de los archivos comprimidos de adjuntos.
- Integridad de los tres SQLite y de los originales de audio por SHA-256/tamaño.
- Exportación y lectura reversible del documento desde la base académica copiada.
- Cifrado AES-256-GCM y descifrado real de ambos paquetes, comprobando igualdad
  SHA-256 con los originales. Prueba de rechazo de contenido alterado y de destinos
  ya existentes; no se publica el texto descifrado hasta validar autenticidad.

`clients/maintenance/recovery_archive.py` requiere Python y cryptography. Ejemplo:

```text
python recovery_archive.py decrypt datos.enc datos.zip --key recovery.key
```

Conservar la clave fuera del paquete y una segunda copia en soporte independiente.
Si solo existe en el ordenador perdido, la copia cifrada remota no es recuperable.
Restaurar siempre primero a un directorio/VM aislado; revisar rutas absolutas y
permisos de la configuración antes del arranque. No ejecutar dumps o archivos de
configuración obtenidos de fuentes no confiables.

El 26/10/2026, tras autorización explícita, se subieron los paquetes cifrados a
Drive privado. Se verificaron nombres, tamaños y estado no compartido. El archivo
de imágenes se dividió en once partes por el límite de transferencia; se adjuntan
manifiesto SHA-256 y utilidad de unión. La clave de descifrado quedó separada en
local. No se ha repetido una descarga y restauración completa desde Drive.
