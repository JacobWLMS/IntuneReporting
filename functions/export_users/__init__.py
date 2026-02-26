"""
Export Entra ID Users (for device enrichment)
Schedule: Once daily
Provides department, office location, account status, etc. for KQL joins with device data.

Required Graph permissions:
  - User.Read.All                (all fields below except signInActivity)
  - AuditLog.Read.All            (optional: enables LastSignInDateTime)
"""
import logging
import asyncio
import azure.functions as func

from msgraph_beta.generated.users.users_request_builder import UsersRequestBuilder
from kiota_abstractions.base_request_configuration import RequestConfiguration

from shared import get_graph_client, add_metadata, DataIngester, retry_with_backoff

logger = logging.getLogger(__name__)

# Properties returned by default (no $select needed):
#   businessPhones, displayName, givenName, id, jobTitle, mail,
#   mobilePhone, officeLocation, preferredLanguage, surname, userPrincipalName
#
# Everything else must be explicitly selected.
_SELECT = [
    'id',
    'userPrincipalName',
    'displayName',
    'givenName',
    'surname',
    'mail',
    'jobTitle',
    'department',
    'officeLocation',
    'city',
    'state',
    'country',
    'usageLocation',
    'employeeId',
    'employeeType',
    'accountEnabled',
    'onPremisesSyncEnabled',
    'onPremisesDistinguishedName',
    'createdDateTime',
    'signInActivity',        # requires AuditLog.Read.All — will be None if not granted
]


async def get_users(graph_client) -> list:
    """Fetch all users with pagination."""
    logger.info("Fetching Entra ID users...")
    users = []

    query_params = UsersRequestBuilder.UsersRequestBuilderGetQueryParameters(
        select=_SELECT,
        top=999,
    )
    request_config = RequestConfiguration(query_parameters=query_params)

    result = await retry_with_backoff(
        graph_client.users.get,
        request_configuration=request_config,
    )

    while result:
        for user in result.value or []:
            sign_in = user.sign_in_activity
            users.append({
                # Identity
                'UserId': user.id,
                'UserPrincipalName': user.user_principal_name,
                'DisplayName': user.display_name,
                'GivenName': user.given_name,
                'Surname': user.surname,
                'Mail': user.mail,

                # Role & org
                'JobTitle': user.job_title,
                'Department': user.department,
                'EmployeeId': user.employee_id,
                'EmployeeType': user.employee_type,

                # Location
                'OfficeLocation': user.office_location,
                'City': user.city,
                'State': user.state,
                'Country': user.country,
                'UsageLocation': user.usage_location,

                # Account status (key for orphaned-device detection)
                'AccountEnabled': user.account_enabled,
                'CreatedDateTime': user.created_date_time.isoformat() if user.created_date_time else None,

                # Hybrid identity
                'OnPremisesSyncEnabled': user.on_premises_sync_enabled,
                'OnPremisesDistinguishedName': user.on_premises_distinguished_name,

                # Sign-in activity (requires AuditLog.Read.All)
                'LastSignInDateTime': (
                    sign_in.last_sign_in_date_time.isoformat()
                    if sign_in and sign_in.last_sign_in_date_time else None
                ),
                'LastNonInteractiveSignInDateTime': (
                    sign_in.last_non_interactive_sign_in_date_time.isoformat()
                    if sign_in and sign_in.last_non_interactive_sign_in_date_time else None
                ),
            })

        if result.odata_next_link:
            result = await retry_with_backoff(
                graph_client.users.with_url(result.odata_next_link).get
            )
        else:
            break

    logger.info(f"Fetched {len(users)} users")
    return users


async def run():
    """Main export logic."""
    logger.info("Starting Entra ID User Export")

    graph_client = get_graph_client()
    ingester = DataIngester()

    users = await get_users(graph_client)
    users = add_metadata(users, 'IntuneUserExport')
    count = ingester.ingest('Users', users)

    logger.info(f"Export completed: {count} users")
    return count


def main(timer: func.TimerRequest) -> None:
    """Azure Function entry point."""
    if timer.past_due:
        logger.warning("Timer is past due")

    asyncio.run(run())
