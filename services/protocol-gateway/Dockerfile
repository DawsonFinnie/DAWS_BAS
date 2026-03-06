# =============================================================================
# services/protocol-gateway/Dockerfile
# =============================================================================
#
# WHAT IS THIS FILE?
# A Dockerfile is a recipe for building a Docker container image.
# Docker reads this file top to bottom and executes each instruction
# to create a self-contained environment for the Protocol Gateway to run in.
#
# WHAT IS A DOCKER IMAGE?
# Think of a Docker image like a snapshot of a complete operating system
# with your application already installed inside it. When you run the image,
# Docker creates a container — a lightweight isolated process that behaves
# the same way on any machine that has Docker installed.
#
# This means: if it works on your laptop, it works on your Proxmox server,
# a cloud VM, or anyone else's machine — no "it works on my machine" problems.
#
# HOW THIS DOCKERFILE WORKS:
#   1. Start FROM an official Python 3.12 image (pre-built Linux + Python)
#   2. Set the working directory inside the container
#   3. Copy requirements.txt and install Python packages
#   4. Copy the rest of the gateway code
#   5. Define the command to run when the container starts
#
# WHY COPY requirements.txt FIRST, BEFORE THE REST OF THE CODE?
# Docker builds images in layers. Each instruction creates a new layer,
# and Docker caches layers that haven't changed.
# By copying requirements.txt and running pip install BEFORE copying the code,
# we get a fast cache hit on the slow pip install step every time we
# change our code but not our dependencies.
# If we copied everything at once, pip would re-run on every single code change.
#
# TO BUILD THIS IMAGE MANUALLY:
#   docker build -t daws-gateway ./services/protocol-gateway
#
# In normal use, docker-compose.yml handles building and running automatically.
#
# =============================================================================


# FROM - the base image to start from
# "python:3.12-slim" is an official Python image from Docker Hub
#   "3.12" = Python version 3.12
#   "slim"  = a minimal Debian Linux install (smaller than the full image)
#             only includes what's needed to run Python
#             no documentation, extra tools, or unnecessary packages
# Using slim keeps our final image small — faster to download and deploy
FROM python:3.12-slim


# WORKDIR - set the working directory inside the container
# All subsequent commands (COPY, RUN, CMD) are relative to this path
# If /app doesn't exist, Docker creates it automatically
# This is equivalent to: mkdir -p /app && cd /app
WORKDIR /app


# COPY requirements.txt first, before the rest of the code
# This takes requirements.txt from your local machine and puts it in /app/
# We do this BEFORE copying the rest of the code for Docker layer caching
# (see explanation above)
# "." as the destination means the current WORKDIR (/app)
COPY requirements.txt .


# RUN - execute a shell command during the image BUILD process
# This installs all Python packages listed in requirements.txt
#
#   pip install        = Python's package installer
#   --no-cache-dir     = don't save pip's download cache inside the image
#                        keeps the image smaller (we don't need the cache
#                        after packages are installed)
#   -r requirements.txt = install all packages listed in the file
RUN pip install --no-cache-dir -r requirements.txt


# COPY the rest of the application code into the container
# First "."  = everything in services/protocol-gateway/ on your local machine
# Second "." = the current WORKDIR in the container (/app/)
# This copies: gateway/__init__.py, gateway/main.py, gateway/bacnet.py, etc.
# It runs AFTER pip install so code changes don't invalidate the pip cache layer
COPY . .


# CMD - the default command to run when the container starts
# This runs when docker-compose brings up this service (not during build)
#
# "python -m gateway.main" means:
#   Run the gateway package's main module
#   Python finds /app/gateway/main.py and executes it
#   Equivalent to: cd /app && python -m gateway.main
#
# Using JSON array format ["python", "-m", "gateway.main"] instead of a
# plain string is best practice — it avoids spawning an intermediate shell,
# which means Docker stop signals (SIGTERM) go directly to Python
# instead of getting swallowed by a shell process
CMD ["python", "-m", "gateway.main"]
