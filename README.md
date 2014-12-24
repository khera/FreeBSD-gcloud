Google Cloud FreeBSD Image Builder
==================================

Here's my script to create Google Cloud images for FreeBSD.

* Requires these pkgs (ports):
  * bar (textproc/bar)
  * google-cloud-sdk (net/google-cloud-sdk)

  It will install these if they are not already installed

* Tweak settings to taste, it will build an image then give you the commands to
  run to upload it to GCE and create an image
