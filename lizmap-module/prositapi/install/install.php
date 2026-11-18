<?php
/**
 * Installazione: crea il diritto "prosit.api.programmi" (gruppo di diritti "Prosit API").
 * L'amministratore lo assegna ai gruppi da Lizmap -> Amministrazione -> Diritti.
 * Rilanciabile: se il diritto esiste gia' non fa nulla.
 */
use Jelix\Installer\Module\API\InstallHelpers;
use Jelix\Installer\Module\Installer;

class prositapiModuleInstaller extends Installer
{
    public function install(InstallHelpers $helpers)
    {
        jAcl2DbManager::createRightGroup('prosit.api.grp', 'prositapi~acl.gruppo');
        jAcl2DbManager::createRight('prosit.api.programmi', 'prositapi~acl.programmi', 'prosit.api.grp');
    }
}
