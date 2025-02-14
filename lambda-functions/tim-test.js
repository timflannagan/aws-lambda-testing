exports.handler = async (event) => {
  console.log('Received event:', JSON.stringify(event, null, 2));

  try {
    // Get numbers from the request
    const num1 = parseInt(event.num1);
    const num2 = parseInt(event.num2);

    // Calculate sum
    const sum = num1 + num2;

    // Prepare response
    const response = {
      statusCode: 200,
      body: JSON.stringify({
        message: `The sum of ${num1} and ${num2} is ${sum}`,
        result: sum
      })
    };

    console.log('Returning response:', JSON.stringify(response, null, 2));
    return response;
  } catch (error) {
    console.error('Error:', error);
    return {
      statusCode: 400,
      body: JSON.stringify({
        message: 'Error processing request',
        error: error.message
      })
    };
  }
};
