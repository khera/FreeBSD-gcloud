Google Cloud FreeBSD Image Builder
==================================

Here's my script to create Google Cloud images for FreeBSD.

* Requires the google-cloud-sdk (net/google-cloud-sdk) pkg/port and will
  install it if it's not installed already

* Tweak settings to taste, it will build an image then give you the commands to
  run to upload it to GCE and create an image

* Script should be run as root
