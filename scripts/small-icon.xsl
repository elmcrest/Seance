<?xml version="1.0"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                xmlns:s="http://www.w3.org/2000/svg">
  <xsl:template match="@*|node()">
    <xsl:copy><xsl:apply-templates select="@*|node()"/></xsl:copy>
  </xsl:template>

  <!-- Keep the CRT glass and phosphors, with transparency outside the screen. -->
  <xsl:template match="s:g[@id='background' or @id='lower-metal-polish']"/>
  <xsl:template match="s:g[@id='rounded-silver-enclosure']">
    <use xmlns="http://www.w3.org/2000/svg" href="#screen-shape" fill="url(#screen-color)"/>
  </xsl:template>
  <xsl:template match="s:svg/@viewBox">
    <xsl:attribute name="viewBox">48 42 930 930</xsl:attribute>
  </xsl:template>
</xsl:stylesheet>
