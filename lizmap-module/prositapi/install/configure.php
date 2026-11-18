<?php
/**
 * Configurazione del modulo: monta urls.xml sul punto di ingresso "api" di Lizmap
 * (lizmap/www/api.php) con il prefisso /prosit. Jelix lo scrive in var/config/localurls.xml,
 * che il backup/ripristino ufficiale di Lizmap conserva negli aggiornamenti.
 */
use Jelix\Installer\Module\API\ConfigurationHelpers;
use Jelix\Installer\Module\Configurator;
use Jelix\Routing\UrlMapping\EntryPointUrlModifier;
use Jelix\Routing\UrlMapping\MapEntry\MapInclude;

class prositapiModuleConfigurator extends Configurator
{
    public function getDefaultParameters()
    {
        return array();
    }

    public function declareUrls(EntryPointUrlModifier $registerOnEntryPoint)
    {
        $registerOnEntryPoint->havingName('api', array(new MapInclude('urls.xml', '/prosit')));
    }

    public function configure(ConfigurationHelpers $helpers)
    {
    }
}
