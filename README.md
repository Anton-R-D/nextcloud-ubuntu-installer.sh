#  Nextcloud en UBUNTU con almacenamiento en STORJ

Este script automatiza la instalación y configuración de **Nextcloud**, integrando almacenamiento en **STORJ** y optimizando la configuración con **Redis** y **MariaDB**.

## 🚀 Características

- Instalación automática de **Nextcloud** en Ubuntu.
- Configuración de **MariaDB** como base de datos.
- Integración con **STORJ** para almacenamiento en la nube.
- Configuración de **Redis** para mejorar el rendimiento.
- Optimización de Apache y PHP para Nextcloud.

## 📌 Requisitos

- **Ubuntu/Debian** dentro del contenedor.
- **Acceso a STORJ** (Bucket, Key, Secret).
- **Dominio o IP fija** para acceder a Nextcloud.

## 🔧 Instalación

1. **Clona el repositorio y accede al directorio:**
   ```bash
   git clone https://github.com/tu-usuario/lxc-nextcloud-storj.git
   cd lxc-nextcloud-storj
